package agent

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRuntimeFailedPollIncrementsOnlyAPIFailureAndRetainsMappings(t *testing.T) {
	runtime, logs := newTestRuntime(t)
	now := time.Date(2026, time.August, 11, 10, 0, 0, 0, time.UTC)
	runtime.now = func() time.Time { return now }
	if err := runtime.cache.ObserveSessions([]Session{{
		ID:             "existing",
		Username:       "alice",
		RemoteEndpoint: "192.0.2.10",
		NowPlaying:     true,
	}}, now); err != nil {
		t.Fatalf("seed mapping cache: %v", err)
	}

	called := make(chan struct{}, 1)
	runtime.fetchSessions = func(context.Context) ([]Session, error) {
		called <- struct{}{}
		return nil, errors.New("sessions unavailable")
	}

	runRuntimeUntilCalled(t, runtime, called)

	metrics := runtime.metrics.Render(runtime.cache.ActiveCount(now))
	assertMetricValue(t, metrics, "jellyfin_egress_jellyfin_api_failures_total", "1")
	assertMetricValue(t, metrics, "jellyfin_egress_access_log_errors_total", "0")
	assertMetricValue(t, metrics, "jellyfin_egress_checkpoint_discontinuities_total", "0")
	if got := runtime.cache.Lookup("192.0.2.10", now); got != "alice" {
		t.Fatalf("mapping after failed poll = %q, want alice", got)
	}
	if !strings.Contains(logs.String(), "poll Jellyfin sessions") {
		t.Fatalf("log = %q, want poll failure", logs.String())
	}
}

func TestRuntimeFailedTailingIncrementsAccessLogErrors(t *testing.T) {
	runtime, logs := newTestRuntime(t)
	called := make(chan struct{}, 1)
	runtime.tailAvailable = func(time.Time) (int, error) {
		called <- struct{}{}
		return 0, errors.New("checkpoint unavailable")
	}

	runRuntimeUntilCalled(t, runtime, called)

	metrics := runtime.metrics.Render(runtime.cache.ActiveCount(runtime.now()))
	assertMetricValue(t, metrics, "jellyfin_egress_access_log_errors_total", "1")
	assertMetricValue(t, metrics, "jellyfin_egress_jellyfin_api_failures_total", "0")
	if !strings.Contains(logs.String(), "tail access log") {
		t.Fatalf("log = %q, want tail failure", logs.String())
	}
}

func TestRuntimeFailedRotationOnlyLogs(t *testing.T) {
	runtime, logs := newTestRuntime(t)
	called := make(chan struct{}, 1)
	runtime.rotateIfNeeded = func() (bool, error) {
		called <- struct{}{}
		return false, errors.New("rotation unavailable")
	}

	runRuntimeUntilCalled(t, runtime, called)

	metrics := runtime.metrics.Render(runtime.cache.ActiveCount(runtime.now()))
	assertMetricValue(t, metrics, "jellyfin_egress_access_log_errors_total", "0")
	assertMetricValue(t, metrics, "jellyfin_egress_jellyfin_api_failures_total", "0")
	assertMetricValue(t, metrics, "jellyfin_egress_checkpoint_discontinuities_total", "0")
	if !strings.Contains(logs.String(), "rotate access log") {
		t.Fatalf("log = %q, want rotation failure", logs.String())
	}
}

func TestRuntimeCancellationStopsIntervalLoopsPromptly(t *testing.T) {
	runtime, _ := newTestRuntime(t)
	pollCalled := make(chan struct{}, 1)
	tailCalled := make(chan struct{}, 1)
	rotateCalled := make(chan struct{}, 1)
	runtime.fetchSessions = func(context.Context) ([]Session, error) {
		pollCalled <- struct{}{}
		return nil, nil
	}
	runtime.tailAvailable = func(time.Time) (int, error) {
		tailCalled <- struct{}{}
		return 0, nil
	}
	runtime.rotateIfNeeded = func() (bool, error) {
		rotateCalled <- struct{}{}
		return false, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	waitForCall(t, pollCalled)
	waitForCall(t, tailCalled)
	waitForCall(t, rotateCalled)
	cancel()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() after cancellation: %v", err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("Run() did not stop interval loops promptly after cancellation")
	}
}

func TestRuntimeUnexpectedComponentExitCancelsSiblings(t *testing.T) {
	runtime, _ := newTestRuntime(t)
	pollStarted := make(chan struct{}, 1)
	runtime.fetchSessions = func(context.Context) ([]Session, error) {
		pollStarted <- struct{}{}
		return nil, nil
	}
	runtime.serveMetrics = func(context.Context) error {
		<-pollStarted
		return nil
	}

	result := make(chan error, 1)
	go func() { result <- runtime.Run(context.Background()) }()

	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "metrics server stopped unexpectedly") {
			t.Fatalf("Run() error = %v, want unexpected metrics-server exit", err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("Run() did not cancel and join sibling components")
	}
}

func TestRuntimeUsesSharedStateAndFileMutex(t *testing.T) {
	runtime, _ := newTestRuntime(t)
	if runtime.tailer.Cache != runtime.cache {
		t.Fatal("tailer does not share the runtime mapping cache")
	}
	if runtime.tailer.Metrics != runtime.metrics {
		t.Fatal("tailer does not share the runtime metric state")
	}
	if runtime.tailer.FileMu != runtime.fileMu || runtime.rotator.FileMu != runtime.fileMu {
		t.Fatal("tailer and rotator do not share the runtime file mutex")
	}
}

func newTestRuntime(t *testing.T) (*Runtime, *bytes.Buffer) {
	t.Helper()
	settings := Settings{
		JellyfinURL:         "http://jellyfin.test",
		APIKey:              "test-key",
		AccessLogPath:       t.TempDir() + "/access.json",
		CheckpointPath:      t.TempDir() + "/checkpoint.json",
		MappingTTL:          time.Hour,
		SessionPollInterval: time.Hour,
		MetricsPort:         9101,
		LogMaxBytes:         1024,
		LogCopies:           2,
		RotationInterval:    time.Hour,
	}
	logs := &bytes.Buffer{}
	runtime := NewRuntime(settings, &http.Client{}, log.New(logs, "", 0))
	runtime.fetchSessions = func(context.Context) ([]Session, error) { return nil, nil }
	runtime.tailAvailable = func(time.Time) (int, error) { return 0, nil }
	runtime.rotateIfNeeded = func() (bool, error) { return false, nil }
	runtime.serveMetrics = func(ctx context.Context) error {
		<-ctx.Done()
		return nil
	}
	return runtime, logs
}

func runRuntimeUntilCalled(t *testing.T, runtime *Runtime, called <-chan struct{}) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	waitForCall(t, called)
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() after cancellation: %v", err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("Run() did not stop after cancellation")
	}
}

func waitForCall(t *testing.T, called <-chan struct{}) {
	t.Helper()
	select {
	case <-called:
	case <-time.After(time.Second):
		t.Fatal("runtime component was not called")
	}
}

func assertMetricValue(t *testing.T, rendered, metric, want string) {
	t.Helper()
	for _, line := range strings.Split(rendered, "\n") {
		if line == metric+" "+want {
			return
		}
	}
	t.Fatalf("metric %s = not %s in:\n%s", metric, want, rendered)
}
