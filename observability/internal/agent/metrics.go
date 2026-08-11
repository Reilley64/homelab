package agent

import (
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// AccessEvent records bytes transferred to a client at a point in time.
type AccessEvent struct {
	ClientIP   string
	ByteCount  int64
	RecordedAt time.Time
}

type metricKey struct {
	username string
	clientIP string
}

// MetricState accumulates the observability agent's Prometheus metrics.
type MetricState struct {
	mu sync.Mutex

	egress                    map[metricKey]uint64
	accessLogErrors           uint64
	jellyfinAPIFailures       uint64
	unattributedBytes         uint64
	checkpointDiscontinuities uint64
}

// Apply records an attributed access event.
func (s *MetricState) Apply(event AccessEvent, username string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.egress == nil {
		s.egress = make(map[metricKey]uint64)
	}
	s.egress[metricKey{username: username, clientIP: event.ClientIP}] += uint64(event.ByteCount)
	if username == "unknown" {
		s.unattributedBytes += uint64(event.ByteCount)
	}
}

// IncrementAccessLogErrors records an access log processing failure.
func (s *MetricState) IncrementAccessLogErrors() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accessLogErrors++
}

// IncrementJellyfinAPIFailures records a failed Jellyfin API request.
func (s *MetricState) IncrementJellyfinAPIFailures() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.jellyfinAPIFailures++
}

// IncrementCheckpointDiscontinuities records an access log checkpoint discontinuity.
func (s *MetricState) IncrementCheckpointDiscontinuities() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.checkpointDiscontinuities++
}

// Render returns Prometheus text exposition metrics for activeMappings.
func (s *MetricState) Render(activeMappings int) string {
	s.mu.Lock()
	egress := make(map[metricKey]uint64, len(s.egress))
	for key, value := range s.egress {
		egress[key] = value
	}
	accessLogErrors := s.accessLogErrors
	jellyfinAPIFailures := s.jellyfinAPIFailures
	unattributedBytes := s.unattributedBytes
	checkpointDiscontinuities := s.checkpointDiscontinuities
	s.mu.Unlock()

	keys := make([]metricKey, 0, len(egress))
	for key := range egress {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].username != keys[j].username {
			return keys[i].username < keys[j].username
		}
		return keys[i].clientIP < keys[j].clientIP
	})

	lines := make([]string, 0, len(keys)+11)
	lines = append(lines, "# TYPE jellyfin_user_egress_bytes_v2_total counter")
	for _, key := range keys {
		lines = append(lines, "jellyfin_user_egress_bytes_v2_total{user=\""+escapePrometheusLabel(key.username)+"\",client_ip=\""+escapePrometheusLabel(key.clientIP)+"\"} "+strconv.FormatUint(egress[key], 10))
	}
	lines = append(lines,
		"# TYPE jellyfin_egress_access_log_errors_total counter",
		"jellyfin_egress_access_log_errors_total "+strconv.FormatUint(accessLogErrors, 10),
		"# TYPE jellyfin_egress_jellyfin_api_failures_total counter",
		"jellyfin_egress_jellyfin_api_failures_total "+strconv.FormatUint(jellyfinAPIFailures, 10),
		"# TYPE jellyfin_egress_unattributed_bytes_total counter",
		"jellyfin_egress_unattributed_bytes_total "+strconv.FormatUint(unattributedBytes, 10),
		"# TYPE jellyfin_egress_checkpoint_discontinuities_total counter",
		"jellyfin_egress_checkpoint_discontinuities_total "+strconv.FormatUint(checkpointDiscontinuities, 10),
		"# TYPE jellyfin_egress_active_ip_mappings gauge",
		"jellyfin_egress_active_ip_mappings "+strconv.Itoa(activeMappings),
	)
	return strings.Join(lines, "\n") + "\n"
}

func escapePrometheusLabel(value string) string {
	return strings.NewReplacer("\\", "\\\\", "\n", "\\n", "\"", "\\\"").Replace(value)
}

// MetricsHandler serves the agent metrics on /metrics.
func MetricsHandler(state *MetricState, cache *MappingCache, now func() time.Time) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Not Implemented", http.StatusNotImplemented)
			return
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = w.Write([]byte(state.Render(cache.ActiveCount(now()))))
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.RequestURI != "/metrics" {
			http.NotFound(w, r)
			return
		}
		mux.ServeHTTP(w, r)
	})
}
