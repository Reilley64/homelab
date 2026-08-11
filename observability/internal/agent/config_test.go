package agent

import (
	"strings"
	"testing"
	"time"
)

func TestLoadSettingsDefaults(t *testing.T) {
	t.Parallel()

	settings, err := LoadSettings(envGetter(map[string]string{
		"JELLYFIN_API_KEY": "secret",
	}))
	if err != nil {
		t.Fatalf("LoadSettings() error = %v", err)
	}

	want := Settings{
		JellyfinURL:         "http://jellyfin:8096",
		APIKey:              "secret",
		AccessLogPath:       "/logs/access.json",
		CheckpointPath:      "/state/checkpoint.json",
		MappingTTL:          600 * time.Second,
		SessionPollInterval: 15 * time.Second,
		MetricsPort:         9101,
		LogMaxBytes:         104857600,
		LogCopies:           7,
		RotationInterval:    60 * time.Second,
	}
	if settings != want {
		t.Errorf("LoadSettings() = %#v, want %#v", settings, want)
	}
}

func TestLoadSettingsRequiresAPIKey(t *testing.T) {
	t.Parallel()

	_, err := LoadSettings(envGetter(nil))
	if err == nil || !strings.Contains(err.Error(), "JELLYFIN_API_KEY") {
		t.Fatalf("LoadSettings() error = %v, want JELLYFIN_API_KEY error", err)
	}
}

func TestLoadSettingsAcceptsFractionalTTLAndPollIntervals(t *testing.T) {
	t.Parallel()

	settings, err := LoadSettings(envGetter(map[string]string{
		"JELLYFIN_API_KEY":     "secret",
		"MAPPING_TTL_SECONDS":  "0.5",
		"SESSION_POLL_SECONDS": "2.25",
	}))
	if err != nil {
		t.Fatalf("LoadSettings() error = %v", err)
	}
	if settings.MappingTTL != 500*time.Millisecond {
		t.Errorf("MappingTTL = %v, want 500ms", settings.MappingTTL)
	}
	if settings.SessionPollInterval != 2250*time.Millisecond {
		t.Errorf("SessionPollInterval = %v, want 2.25s", settings.SessionPollInterval)
	}
}

func TestLoadSettingsRejectsInvalidNumericValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		key   string
		value string
	}{
		{"invalid mapping ttl", "MAPPING_TTL_SECONDS", "nope"},
		{"zero mapping ttl", "MAPPING_TTL_SECONDS", "0"},
		{"negative mapping ttl", "MAPPING_TTL_SECONDS", "-1"},
		{"invalid poll interval", "SESSION_POLL_SECONDS", "nope"},
		{"zero poll interval", "SESSION_POLL_SECONDS", "0"},
		{"negative poll interval", "SESSION_POLL_SECONDS", "-1"},
		{"fractional rotation interval", "ROTATION_CHECK_SECONDS", "1.5"},
		{"zero rotation interval", "ROTATION_CHECK_SECONDS", "0"},
		{"negative rotation interval", "ROTATION_CHECK_SECONDS", "-1"},
		{"fractional log max bytes", "LOG_MAX_BYTES", "1.5"},
		{"zero log max bytes", "LOG_MAX_BYTES", "0"},
		{"negative log max bytes", "LOG_MAX_BYTES", "-1"},
		{"fractional log copies", "LOG_COPIES", "1.5"},
		{"zero log copies", "LOG_COPIES", "0"},
		{"negative log copies", "LOG_COPIES", "-1"},
		{"fractional metrics port", "METRICS_PORT", "9101.5"},
		{"zero metrics port", "METRICS_PORT", "0"},
		{"negative metrics port", "METRICS_PORT", "-1"},
		{"too large metrics port", "METRICS_PORT", "65536"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			values := map[string]string{
				"JELLYFIN_API_KEY": "secret",
				test.key:           test.value,
			}
			_, err := LoadSettings(envGetter(values))
			if err == nil || !strings.Contains(err.Error(), test.key) {
				t.Fatalf("LoadSettings() error = %v, want %s error", err, test.key)
			}
		})
	}
}

func envGetter(values map[string]string) func(string) string {
	return func(key string) string {
		return values[key]
	}
}
