package agent

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricStateRenderAccumulatesAndIncludesDiagnostics(t *testing.T) {
	t.Parallel()

	state := &MetricState{}
	event := AccessEvent{ClientIP: "203.0.113.8", ByteCount: 4096, RecordedAt: time.Unix(1000, 0)}
	state.Apply(event, "alice")
	state.Apply(event, "alice")

	rendered := state.Render(1)
	for _, want := range []string{
		"# TYPE jellyfin_user_egress_bytes_v2_total counter",
		"jellyfin_user_egress_bytes_v2_total{user=\"alice\",client_ip=\"203.0.113.8\"} 8192",
		"# TYPE jellyfin_egress_access_log_errors_total counter",
		"jellyfin_egress_access_log_errors_total 0",
		"# TYPE jellyfin_egress_jellyfin_api_failures_total counter",
		"jellyfin_egress_jellyfin_api_failures_total 0",
		"# TYPE jellyfin_egress_unattributed_bytes_total counter",
		"jellyfin_egress_unattributed_bytes_total 0",
		"# TYPE jellyfin_egress_checkpoint_discontinuities_total counter",
		"jellyfin_egress_checkpoint_discontinuities_total 0",
		"# TYPE jellyfin_egress_active_ip_mappings gauge",
		"jellyfin_egress_active_ip_mappings 1",
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("Render() missing %q:\n%s", want, rendered)
		}
	}
	if strings.Contains(rendered, "jellyfin_user_egress_bytes_total{") {
		t.Errorf("Render() included legacy metric:\n%s", rendered)
	}
}

func TestMetricStateRenderSortsKeysAndTracksUnknownBytes(t *testing.T) {
	t.Parallel()

	state := &MetricState{}
	state.Apply(AccessEvent{ClientIP: "203.0.113.9", ByteCount: 3}, "zara")
	state.Apply(AccessEvent{ClientIP: "203.0.113.8", ByteCount: 2}, "alice")
	state.Apply(AccessEvent{ClientIP: "203.0.113.7", ByteCount: 5}, "unknown")

	rendered := state.Render(0)
	alice := strings.Index(rendered, `user="alice",client_ip="203.0.113.8"`)
	unknown := strings.Index(rendered, `user="unknown",client_ip="203.0.113.7"`)
	zara := strings.Index(rendered, `user="zara",client_ip="203.0.113.9"`)
	if alice < 0 || unknown < 0 || zara < 0 || !(alice < unknown && unknown < zara) {
		t.Errorf("Render() keys are not sorted by user and IP:\n%s", rendered)
	}
	if !strings.Contains(rendered, "jellyfin_egress_unattributed_bytes_total 5") {
		t.Errorf("Render() did not report unknown bytes:\n%s", rendered)
	}
}

func TestMetricStateRenderEscapesPrometheusLabels(t *testing.T) {
	t.Parallel()

	state := &MetricState{}
	state.Apply(AccessEvent{ClientIP: "line\n\\\"ip", ByteCount: 1}, "a\n\\\"b")

	if got := state.Render(0); !strings.Contains(got, `user="a\n\\\"b",client_ip="line\n\\\"ip"`) {
		t.Errorf("Render() did not escape labels:\n%s", got)
	}
}

func TestMetricStateIncrementsDiagnosticCounters(t *testing.T) {
	t.Parallel()

	state := &MetricState{}
	state.IncrementAccessLogErrors()
	state.IncrementJellyfinAPIFailures()
	state.IncrementCheckpointDiscontinuities()

	rendered := state.Render(0)
	for _, want := range []string{
		"jellyfin_egress_access_log_errors_total 1",
		"jellyfin_egress_jellyfin_api_failures_total 1",
		"jellyfin_egress_checkpoint_discontinuities_total 1",
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("Render() missing incremented counter %q:\n%s", want, rendered)
		}
	}
}

func TestMetricsHandlerServesMetricsOnly(t *testing.T) {
	t.Parallel()

	state := &MetricState{}
	cache := NewMappingCache(time.Minute)
	now := time.Unix(1000, 0)
	if err := cache.ObserveSessions([]Session{{Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true}}, now); err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	handler := MetricsHandler(state, cache, func() time.Time { return now })

	metrics := httptest.NewRecorder()
	handler.ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if metrics.Code != http.StatusOK {
		t.Errorf("/metrics status = %d, want %d", metrics.Code, http.StatusOK)
	}
	if got := metrics.Header().Get("Content-Type"); got != "text/plain; version=0.0.4; charset=utf-8" {
		t.Errorf("/metrics Content-Type = %q", got)
	}
	if !strings.Contains(metrics.Body.String(), "jellyfin_egress_active_ip_mappings 1") {
		t.Errorf("/metrics body missing active mapping gauge:\n%s", metrics.Body.String())
	}

	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/health", nil))
	if health.Code != http.StatusNotFound {
		t.Errorf("/health status = %d, want %d", health.Code, http.StatusNotFound)
	}

	post := httptest.NewRecorder()
	handler.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/metrics", nil))
	if post.Code != http.StatusNotImplemented {
		t.Errorf("POST /metrics status = %d, want %d", post.Code, http.StatusNotImplemented)
	}

	query := httptest.NewRecorder()
	handler.ServeHTTP(query, httptest.NewRequest(http.MethodGet, "/metrics?format=prometheus", nil))
	if query.Code != http.StatusNotFound {
		t.Errorf("GET /metrics with query status = %d, want %d", query.Code, http.StatusNotFound)
	}
}
