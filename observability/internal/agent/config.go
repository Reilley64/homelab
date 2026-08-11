package agent

import (
	"fmt"
	"math"
	"strconv"
	"time"
)

const (
	defaultJellyfinURL       = "http://jellyfin:8096"
	defaultAccessLogPath     = "/logs/access.json"
	defaultCheckpointPath    = "/state/checkpoint.json"
	defaultMappingTTL        = "600"
	defaultSessionPoll       = "15"
	defaultMetricsPort       = "9101"
	defaultLogMaxBytes       = "104857600"
	defaultLogCopies         = "7"
	defaultRotationCheckTime = "60"
)

// Settings configures the observability agent.
type Settings struct {
	JellyfinURL         string
	APIKey              string
	AccessLogPath       string
	CheckpointPath      string
	MappingTTL          time.Duration
	SessionPollInterval time.Duration
	MetricsPort         int
	LogMaxBytes         int64
	LogCopies           int
	RotationInterval    time.Duration
}

// LoadSettings loads the observability agent configuration from getenv.
func LoadSettings(getenv func(string) string) (Settings, error) {
	apiKey := getenv("JELLYFIN_API_KEY")
	if apiKey == "" {
		return Settings{}, fmt.Errorf("JELLYFIN_API_KEY is required")
	}

	mappingTTL, err := positiveSeconds("MAPPING_TTL_SECONDS", valueOrDefault(getenv, "MAPPING_TTL_SECONDS", defaultMappingTTL))
	if err != nil {
		return Settings{}, err
	}
	sessionPoll, err := positiveSeconds("SESSION_POLL_SECONDS", valueOrDefault(getenv, "SESSION_POLL_SECONDS", defaultSessionPoll))
	if err != nil {
		return Settings{}, err
	}
	metricsPort, err := positiveInt("METRICS_PORT", valueOrDefault(getenv, "METRICS_PORT", defaultMetricsPort))
	if err != nil {
		return Settings{}, err
	}
	if metricsPort > 65535 {
		return Settings{}, fmt.Errorf("METRICS_PORT must be between 1 and 65535")
	}
	logMaxBytes, err := positiveInt64("LOG_MAX_BYTES", valueOrDefault(getenv, "LOG_MAX_BYTES", defaultLogMaxBytes))
	if err != nil {
		return Settings{}, err
	}
	logCopies, err := positiveInt("LOG_COPIES", valueOrDefault(getenv, "LOG_COPIES", defaultLogCopies))
	if err != nil {
		return Settings{}, err
	}
	rotationInterval, err := positiveIntegerSeconds("ROTATION_CHECK_SECONDS", valueOrDefault(getenv, "ROTATION_CHECK_SECONDS", defaultRotationCheckTime))
	if err != nil {
		return Settings{}, err
	}

	return Settings{
		JellyfinURL:         valueOrDefault(getenv, "JELLYFIN_URL", defaultJellyfinURL),
		APIKey:              apiKey,
		AccessLogPath:       valueOrDefault(getenv, "ACCESS_LOG_PATH", defaultAccessLogPath),
		CheckpointPath:      valueOrDefault(getenv, "CHECKPOINT_PATH", defaultCheckpointPath),
		MappingTTL:          mappingTTL,
		SessionPollInterval: sessionPoll,
		MetricsPort:         metricsPort,
		LogMaxBytes:         logMaxBytes,
		LogCopies:           logCopies,
		RotationInterval:    rotationInterval,
	}, nil
}

func valueOrDefault(getenv func(string) string, key, fallback string) string {
	if value := getenv(key); value != "" {
		return value
	}
	return fallback
}

func positiveSeconds(name, value string) (time.Duration, error) {
	seconds, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds <= 0 {
		return 0, fmt.Errorf("%s must be a positive number of seconds", name)
	}
	if seconds > float64(math.MaxInt64)/float64(time.Second) {
		return 0, fmt.Errorf("%s is too large", name)
	}
	duration := time.Duration(seconds * float64(time.Second))
	if duration <= 0 {
		return 0, fmt.Errorf("%s must be a positive number of seconds", name)
	}
	return duration, nil
}

func positiveIntegerSeconds(name, value string) (time.Duration, error) {
	seconds, err := positiveInt64(name, value)
	if err != nil {
		return 0, err
	}
	if seconds > int64(math.MaxInt64/time.Second) {
		return 0, fmt.Errorf("%s is too large", name)
	}
	return time.Duration(seconds) * time.Second, nil
}

func positiveInt(name, value string) (int, error) {
	parsed, err := strconv.ParseInt(value, 10, 0)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return int(parsed), nil
}

func positiveInt64(name, value string) (int64, error) {
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return parsed, nil
}
