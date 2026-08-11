package agent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

const (
	accessLogTailInterval  = time.Second
	metricsShutdownTimeout = 5 * time.Second
)

// Runtime coordinates the observability agent components.
type Runtime struct {
	settings Settings
	logger   *log.Logger

	cache   *MappingCache
	metrics *MetricState
	fileMu  *sync.Mutex
	client  *JellyfinClient
	tailer  *Tailer
	rotator *Rotator

	fetchSessions  func(context.Context) ([]Session, error)
	tailAvailable  func(time.Time) (int, error)
	rotateIfNeeded func() (bool, error)
	now            func() time.Time
	serveMetrics   func(context.Context) error
}

// NewRuntime constructs a runtime whose tailer and rotator coordinate access
// to the active log through one shared mutex.
func NewRuntime(settings Settings, httpClient *http.Client, logger *log.Logger) *Runtime {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}

	cache := NewMappingCache(settings.MappingTTL)
	metrics := &MetricState{}
	fileMu := &sync.Mutex{}
	client := &JellyfinClient{
		BaseURL:    settings.JellyfinURL,
		APIKey:     settings.APIKey,
		HTTPClient: httpClient,
	}
	tailer := &Tailer{
		LogPath:        settings.AccessLogPath,
		CheckpointPath: settings.CheckpointPath,
		Cache:          cache,
		Metrics:        metrics,
		FileMu:         fileMu,
	}
	rotator := &Rotator{
		Path:     settings.AccessLogPath,
		MaxBytes: settings.LogMaxBytes,
		Copies:   settings.LogCopies,
		FileMu:   fileMu,
	}

	runtime := &Runtime{
		settings:       settings,
		logger:         logger,
		cache:          cache,
		metrics:        metrics,
		fileMu:         fileMu,
		client:         client,
		tailer:         tailer,
		rotator:        rotator,
		fetchSessions:  client.FetchSessions,
		tailAvailable:  tailer.ProcessAvailable,
		rotateIfNeeded: rotator.RotateIfNeeded,
		now:            time.Now,
	}
	runtime.serveMetrics = runtime.runMetricsServer
	return runtime
}

// Run starts every top-level component and stops all siblings when the parent
// context is canceled or any component exits unexpectedly.
func (r *Runtime) Run(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	components := []runtimeComponent{
		{name: "session poller", run: r.runSessionPoller},
		{name: "access log tailer", run: r.runAccessLogTailer},
		{name: "log rotator", run: r.runLogRotator},
		{name: "metrics server", run: r.serveMetrics},
	}
	results := make(chan componentResult, len(components))
	for _, component := range components {
		component := component
		go func() {
			results <- componentResult{name: component.name, err: component.run(runCtx)}
		}()
	}

	first := <-results
	unexpected := ctx.Err() == nil
	cancel()
	for range len(components) - 1 {
		<-results
	}

	if !unexpected {
		return nil
	}
	if first.err != nil {
		return fmt.Errorf("%s: %w", first.name, first.err)
	}
	return fmt.Errorf("%s stopped unexpectedly", first.name)
}

type runtimeComponent struct {
	name string
	run  func(context.Context) error
}

type componentResult struct {
	name string
	err  error
}

func (r *Runtime) runSessionPoller(ctx context.Context) error {
	return runInterval(ctx, r.settings.SessionPollInterval, func() {
		sessions, err := r.fetchSessions(ctx)
		if err == nil {
			err = r.cache.ObserveSessions(sessions, r.now())
		}
		if err != nil {
			if errors.Is(err, context.Canceled) && ctx.Err() != nil {
				return
			}
			r.metrics.IncrementJellyfinAPIFailures()
			r.logger.Printf("poll Jellyfin sessions: %v", err)
		}
	})
}

func (r *Runtime) runAccessLogTailer(ctx context.Context) error {
	return runInterval(ctx, accessLogTailInterval, func() {
		if _, err := r.tailAvailable(r.now()); err != nil {
			r.metrics.IncrementAccessLogErrors()
			r.logger.Printf("tail access log: %v", err)
		}
	})
}

func (r *Runtime) runLogRotator(ctx context.Context) error {
	return runInterval(ctx, r.settings.RotationInterval, func() {
		if _, err := r.rotateIfNeeded(); err != nil {
			r.logger.Printf("rotate access log: %v", err)
		}
	})
}

func runInterval(ctx context.Context, interval time.Duration, action func()) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		action()
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return nil
		case <-timer.C:
		}
	}
}

func (r *Runtime) runMetricsServer(ctx context.Context) error {
	server := &http.Server{
		Addr:    fmt.Sprintf("0.0.0.0:%d", r.settings.MetricsPort),
		Handler: MetricsHandler(r.metrics, r.cache, r.now),
	}
	result := make(chan error, 1)
	go func() {
		result <- server.ListenAndServe()
	}()

	select {
	case err := <-result:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), metricsShutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
			return fmt.Errorf("shut down metrics server: %w", err)
		}
		err := <-result
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
