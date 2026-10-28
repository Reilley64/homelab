package agent

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestNormalizeAddress(t *testing.T) {
	t.Parallel()

	valid := map[string]string{
		"203.0.113.8:44321":   "203.0.113.8",
		"::ffff:203.0.113.8":  "203.0.113.8",
		"[2001:db8::8]":       "2001:db8::8",
		"[2001:db8::8]:44321": "2001:db8::8",
	}
	for input, want := range valid {
		got, ok := normalizeAddress(input)
		if !ok || got != want {
			t.Errorf("normalizeAddress(%q) = %q, %t; want %q, true", input, got, ok, want)
		}
	}

	for _, input := range []string{"", "not-an-address", "[2001:db8::8]junk", "[2001:db8::8]:invalid"} {
		if got, ok := normalizeAddress(input); ok {
			t.Errorf("normalizeAddress(%q) = %q, true; want invalid", input, got)
		}
	}
}

func TestJellyfinClientFetchSessions(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/Sessions" {
			t.Errorf("path = %s, want /Sessions", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != `MediaBrowser Token="secret"` {
			t.Errorf("Authorization = %q, want MediaBrowser Token=\"secret\"", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept = %q, want application/json", got)
		}
		_, _ = w.Write([]byte(`[{"Id":"session-1","UserName":"alice","RemoteEndPoint":"203.0.113.8:5000","NowPlayingItem":{"Id":"item-1"}}]`))
	}))
	defer server.Close()

	client := JellyfinClient{BaseURL: server.URL, APIKey: "secret", HTTPClient: server.Client()}
	got, err := client.FetchSessions(context.Background())
	if err != nil {
		t.Fatalf("FetchSessions() error = %v", err)
	}
	want := []Session{{
		ID:             "session-1",
		Username:       "alice",
		RemoteEndpoint: "203.0.113.8:5000",
		NowPlaying:     true,
	}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("FetchSessions() = %#v, want %#v", got, want)
	}
}

func TestSessionRejectsNonObjectJSON(t *testing.T) {
	t.Parallel()

	for _, input := range []string{"null", `[]`, `"session"`, `1`, `true`} {
		var session Session
		if err := json.Unmarshal([]byte(input), &session); err == nil {
			t.Errorf("json.Unmarshal(%s) error = nil, want non-object error", input)
		}
	}
}

func TestJellyfinClientRejectsNullSessionElement(t *testing.T) {
	t.Parallel()

	client := JellyfinClient{
		BaseURL: "http://jellyfin.test",
		APIKey:  "secret",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(`[{"Id":"new","UserName":"alice","RemoteEndPoint":"203.0.113.8","NowPlayingItem":{"Id":"item-1"}},null]`)),
				Request:    request,
			}, nil
		})},
	}
	sessions, err := client.FetchSessions(context.Background())
	if err == nil {
		t.Fatal("FetchSessions() error = nil, want null-session error")
	}
	if sessions != nil {
		t.Errorf("FetchSessions() sessions = %#v, want nil after invalid response", sessions)
	}
}

func TestJellyfinClientDefaultHTTPClientBoundsRequests(t *testing.T) {
	originalTransport := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = originalTransport })

	var deadlineRemaining time.Duration
	var sawDeadline bool
	http.DefaultTransport = roundTripFunc(func(request *http.Request) (*http.Response, error) {
		deadline, ok := request.Context().Deadline()
		if ok {
			sawDeadline = true
			deadlineRemaining = time.Until(deadline)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader("[]")),
			Request:    request,
		}, nil
	})

	client := JellyfinClient{BaseURL: "http://jellyfin.invalid", APIKey: "secret"}
	if _, err := client.FetchSessions(context.Background()); err != nil {
		t.Fatalf("FetchSessions() error = %v", err)
	}
	if !sawDeadline {
		t.Fatal("default HTTP request has no deadline, want ten-second bound")
	}
	const expectedTimeout = 10 * time.Second
	const schedulingTolerance = 250 * time.Millisecond
	if deadlineRemaining < expectedTimeout-schedulingTolerance || deadlineRemaining > expectedTimeout {
		t.Errorf("default HTTP request deadline remaining = %v, want within %v of %v", deadlineRemaining, schedulingTolerance, expectedTimeout)
	}
}

func TestJellyfinClientRejectsNonListAndNonSuccessResponses(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		status int
		body   string
	}{
		{"non-list json", http.StatusOK, `{}`},
		{"non-success response", http.StatusBadGateway, `[]`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()

			client := JellyfinClient{BaseURL: server.URL, APIKey: "secret", HTTPClient: server.Client()}
			if _, err := client.FetchSessions(context.Background()); err == nil {
				t.Fatal("FetchSessions() error = nil, want error")
			}
		})
	}
}

func TestJellyfinClientRespectsCanceledContext(t *testing.T) {
	t.Parallel()

	client := JellyfinClient{BaseURL: "http://127.0.0.1:1", APIKey: "secret"}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := client.FetchSessions(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("FetchSessions() error = %v, want context cancellation", err)
	}
}

func TestMappingCacheFiltersIdleSessionsAndUsesLastSharedIP(t *testing.T) {
	t.Parallel()

	cache := NewMappingCache(10 * time.Minute)
	err := cache.ObserveSessions([]Session{
		{ID: "playing-1", Username: "alice", RemoteEndpoint: "203.0.113.8:5000", NowPlaying: true},
		{ID: "idle", Username: "idle", RemoteEndpoint: "203.0.113.9:5000", NowPlaying: false},
		{ID: "playing-2", Username: "bob", RemoteEndpoint: "203.0.113.8:5001", NowPlaying: true},
	}, time.Unix(1000, 0))
	if err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	if got := cache.Lookup("203.0.113.8", time.Unix(1001, 0)); got != "bob" {
		t.Errorf("Lookup(shared IP) = %q, want bob", got)
	}
	if got := cache.Lookup("203.0.113.9", time.Unix(1001, 0)); got != "unknown" {
		t.Errorf("Lookup(idle IP) = %q, want unknown", got)
	}
}

func TestMappingCacheExpiresOnlyAfterTTL(t *testing.T) {
	t.Parallel()

	cache := NewMappingCache(10 * time.Minute)
	if err := cache.ObserveSessions([]Session{{
		ID: "playing", Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true,
	}}, time.Unix(1000, 0)); err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	if got := cache.Lookup("203.0.113.8", time.Unix(1600, 0)); got != "alice" {
		t.Errorf("Lookup(at TTL) = %q, want alice", got)
	}
	if got := cache.Lookup("203.0.113.8", time.Unix(1600, 1)); got != "unknown" {
		t.Errorf("Lookup(after TTL) = %q, want unknown", got)
	}
	if got := cache.ActiveCount(time.Unix(1600, 1)); got != 0 {
		t.Errorf("ActiveCount() = %d, want 0", got)
	}
}

func TestMappingCacheDoesNotApplyPartialUpdates(t *testing.T) {
	t.Parallel()

	cache := NewMappingCache(10 * time.Minute)
	if err := cache.ObserveSessions([]Session{{
		ID: "existing", Username: "existing", RemoteEndpoint: "203.0.113.9", NowPlaying: true,
	}}, time.Unix(100, 0)); err != nil {
		t.Fatalf("ObserveSessions() initial error = %v", err)
	}

	err := cache.ObserveSessions([]Session{
		{ID: "new", Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true},
		{ID: "invalid", Username: "bob", RemoteEndpoint: "not-an-address", NowPlaying: true},
	}, time.Unix(101, 0))
	if err == nil {
		t.Fatal("ObserveSessions() error = nil, want invalid session error")
	}
	if got := cache.Lookup("203.0.113.9", time.Unix(101, 0)); got != "existing" {
		t.Errorf("Lookup(existing) = %q, want existing", got)
	}
	if got := cache.Lookup("203.0.113.8", time.Unix(101, 0)); got != "unknown" {
		t.Errorf("Lookup(partial update) = %q, want unknown", got)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}
