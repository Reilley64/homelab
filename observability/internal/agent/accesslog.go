package agent

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

const publicJellyfinRouter = "jellyfin@docker"

var rfc3339Timestamp = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$`)

// ParseAccessLine parses a public Jellyfin Traefik access-log record.
// It returns nil, nil for records belonging to another router.
func ParseAccessLine(line []byte) (*AccessEvent, error) {
	var entry map[string]json.RawMessage
	if err := json.Unmarshal(line, &entry); err != nil || entry == nil {
		if err != nil {
			return nil, fmt.Errorf("decode access log JSON: %w", err)
		}
		return nil, fmt.Errorf("access log entry must be a JSON object")
	}

	var router string
	if rawRouter, ok := entry["RouterName"]; ok {
		if err := json.Unmarshal(rawRouter, &router); err != nil {
			return nil, nil
		}
	}
	if router != publicJellyfinRouter {
		return nil, nil
	}

	byteCount, err := parseByteCount(entry["DownstreamContentSize"])
	if err != nil {
		return nil, err
	}
	clientIP, err := parseClientHost(entry["ClientHost"])
	if err != nil {
		return nil, err
	}
	recordedAt, err := parseRecordedAt(entry["time"])
	if err != nil {
		return nil, err
	}

	return &AccessEvent{ClientIP: clientIP, ByteCount: byteCount, RecordedAt: recordedAt}, nil
}

func parseByteCount(raw json.RawMessage) (int64, error) {
	if len(raw) == 0 {
		return 0, fmt.Errorf("DownstreamContentSize must be a non-negative integer")
	}
	byteCount, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil || byteCount < 0 {
		return 0, fmt.Errorf("DownstreamContentSize must be a non-negative integer")
	}
	return byteCount, nil
}

func parseClientHost(raw json.RawMessage) (string, error) {
	var clientHost string
	if len(raw) == 0 || json.Unmarshal(raw, &clientHost) != nil {
		return "", fmt.Errorf("ClientHost must be an IP address")
	}
	clientIP, ok := normalizeAddress(clientHost)
	if !ok {
		return "", fmt.Errorf("ClientHost must be an IP address")
	}
	return clientIP, nil
}

func parseRecordedAt(raw json.RawMessage) (time.Time, error) {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || !rfc3339Timestamp.MatchString(value) || !validRFC3339Timestamp(value) {
		return time.Time{}, fmt.Errorf("time must be a timezone-aware RFC 3339 timestamp")
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("time must be a timezone-aware RFC 3339 timestamp")
	}
	return parsed, nil
}

func validRFC3339Timestamp(value string) bool {
	if value[:4] == "0000" {
		return false
	}
	if value[len(value)-1] == 'Z' {
		return true
	}
	offsetHour, _ := strconv.Atoi(value[len(value)-5 : len(value)-3])
	return offsetHour < 24
}
