package agent

import (
	"encoding/json"
	"testing"
)

func TestParseAccessLineReturnsPublicJellyfinEvent(t *testing.T) {
	t.Parallel()

	event, err := ParseAccessLine(accessLine(t, nil))
	if err != nil {
		t.Fatalf("ParseAccessLine() error = %v", err)
	}
	if event == nil {
		t.Fatal("ParseAccessLine() = nil, want event")
	}
	if event.ClientIP != "203.0.113.8" {
		t.Errorf("ClientIP = %q, want 203.0.113.8", event.ClientIP)
	}
	if event.ByteCount != 4096 {
		t.Errorf("ByteCount = %d, want 4096", event.ByteCount)
	}
	if got := event.RecordedAt.Unix(); got != 1786270480 {
		t.Errorf("RecordedAt.Unix() = %d, want 1786270480", got)
	}
}

func TestParseAccessLineAcceptsTimezoneAwareRFC3339Shapes(t *testing.T) {
	t.Parallel()

	for _, timestamp := range []string{
		"2026-08-09T20:14:40Z",
		"2026-08-09T20:14:40+10:00",
		"2026-08-09T20:14:40.123456789-07:00",
	} {
		t.Run(timestamp, func(t *testing.T) {
			line := accessLine(t, map[string]any{"time": timestamp})
			event, err := ParseAccessLine(line)
			if err != nil {
				t.Fatalf("ParseAccessLine() error = %v", err)
			}
			if event == nil || event.RecordedAt.IsZero() {
				t.Fatalf("ParseAccessLine() = %#v, want timestamped event", event)
			}
		})
	}
}

func TestParseAccessLineIgnoresLANAndOtherRouters(t *testing.T) {
	t.Parallel()

	for _, router := range []string{"jellyfinlocal@docker", "grafana@docker", ""} {
		t.Run(router, func(t *testing.T) {
			event, err := ParseAccessLine(accessLine(t, map[string]any{"RouterName": router}))
			if err != nil {
				t.Fatalf("ParseAccessLine() error = %v", err)
			}
			if event != nil {
				t.Errorf("ParseAccessLine() = %#v, want ignored line", event)
			}
		})
	}
}

func TestParseAccessLineRejectsInvalidByteCounts(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name      string
		byteCount any
	}{
		{"negative", -1},
		{"string", "4096"},
		{"fractional", 1.5},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := ParseAccessLine(accessLine(t, map[string]any{"DownstreamContentSize": test.byteCount}))
			if err == nil {
				t.Fatalf("ParseAccessLine(%v) error = nil, want invalid byte count", test.byteCount)
			}
		})
	}
}

func TestParseAccessLineRejectsInvalidClientHostTypes(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name       string
		clientHost any
	}{
		{"null", nil},
		{"number", 42},
		{"invalid address", "not-an-address"},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := ParseAccessLine(accessLine(t, map[string]any{"ClientHost": test.clientHost}))
			if err == nil {
				t.Fatalf("ParseAccessLine(%v) error = nil, want invalid client host", test.clientHost)
			}
		})
	}
}

func TestParseAccessLineRejectsMalformedJSONAndTimestampShapes(t *testing.T) {
	t.Parallel()

	if _, err := ParseAccessLine([]byte(`{"RouterName":`)); err == nil {
		t.Fatal("ParseAccessLine(malformed JSON) error = nil, want error")
	}

	for _, timestamp := range []any{
		nil,
		"2026-08-09T20:14:40",
		"20260809T201440+1000",
		"2026-08-09 20:14:40+10:00",
		"2026-08-09T20:14:40+10",
		"not-a-time",
	} {
		t.Run("invalid timestamp", func(t *testing.T) {
			_, err := ParseAccessLine(accessLine(t, map[string]any{"time": timestamp}))
			if err == nil {
				t.Fatalf("ParseAccessLine(%v) error = nil, want invalid timestamp", timestamp)
			}
		})
	}
}

func TestParseAccessLineRejectsTimestampValuesPythonWouldReject(t *testing.T) {
	t.Parallel()

	for _, timestamp := range []string{
		"0000-08-09T20:14:40Z",
		"2026-08-09T20:14:40+24:00",
		"2026-08-09T20:14:40-24:00",
		"2026-08-09T20:14:40+23:60",
		"2026-08-09T20:14:40-23:60",
	} {
		t.Run(timestamp, func(t *testing.T) {
			_, err := ParseAccessLine(accessLine(t, map[string]any{"time": timestamp}))
			if err == nil {
				t.Fatalf("ParseAccessLine(%q) error = nil, want invalid timestamp", timestamp)
			}
		})
	}
}

func TestParseAccessLineAcceptsNearBoundaryTimezoneOffset(t *testing.T) {
	t.Parallel()

	event, err := ParseAccessLine(accessLine(t, map[string]any{"time": "2026-08-09T20:14:40+23:59"}))
	if err != nil {
		t.Fatalf("ParseAccessLine() error = %v", err)
	}
	if event == nil {
		t.Fatal("ParseAccessLine() = nil, want event")
	}
}

func TestParseAccessLineAcceptsPythonNoncanonicalTimezoneOffsets(t *testing.T) {
	t.Parallel()

	for _, timestamp := range []string{
		"2026-08-09T20:14:40+00:60",
		"2026-08-09T20:14:40+10:99",
		"2026-08-09T20:14:40+22:99",
		"2026-08-09T20:14:40-10:99",
	} {
		t.Run(timestamp, func(t *testing.T) {
			event, err := ParseAccessLine(accessLine(t, map[string]any{"time": timestamp}))
			if err != nil {
				t.Fatalf("ParseAccessLine() error = %v", err)
			}
			if event == nil {
				t.Fatal("ParseAccessLine() = nil, want event")
			}
		})
	}
}

func accessLine(t *testing.T, overrides map[string]any) []byte {
	t.Helper()
	entry := map[string]any{
		"RouterName":            "jellyfin@docker",
		"ClientHost":            "203.0.113.8",
		"DownstreamContentSize": 4096,
		"time":                  "2026-08-09T20:14:40+10:00",
	}
	for key, value := range overrides {
		entry[key] = value
	}
	line, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	return line
}
