package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

const jellyfinRequestTimeout = 10 * time.Second

// Session is the portion of a Jellyfin session used for traffic attribution.
type Session struct {
	ID             string
	Username       string
	RemoteEndpoint string
	NowPlaying     bool
}

// UnmarshalJSON identifies active playback by a non-null NowPlayingItem.
func (s *Session) UnmarshalJSON(data []byte) error {
	if trimmed := bytes.TrimSpace(data); len(trimmed) == 0 || trimmed[0] != '{' {
		return fmt.Errorf("Jellyfin session must be an object")
	}

	var wire struct {
		ID             string           `json:"Id"`
		Username       string           `json:"UserName"`
		RemoteEndpoint string           `json:"RemoteEndPoint"`
		NowPlayingItem *json.RawMessage `json:"NowPlayingItem"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	*s = Session{
		ID:             wire.ID,
		Username:       wire.Username,
		RemoteEndpoint: wire.RemoteEndpoint,
		NowPlaying:     wire.NowPlayingItem != nil,
	}
	return nil
}

// JellyfinClient fetches active sessions from the Jellyfin API.
type JellyfinClient struct {
	BaseURL    string
	APIKey     string
	HTTPClient *http.Client
}

// FetchSessions retrieves the current Jellyfin sessions.
func (c JellyfinClient) FetchSessions(ctx context.Context) ([]Session, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(c.BaseURL, "/")+"/Sessions", nil)
	if err != nil {
		return nil, fmt.Errorf("create Jellyfin /Sessions request: %w", err)
	}
	request.Header.Set("X-Emby-Token", c.APIKey)
	request.Header.Set("Accept", "application/json")

	client := c.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: jellyfinRequestTimeout}
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("Jellyfin /Sessions returned HTTP %d", response.StatusCode)
	}

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("read Jellyfin /Sessions response: %w", err)
	}
	if !bytes.HasPrefix(bytes.TrimSpace(body), []byte("[")) {
		return nil, fmt.Errorf("Jellyfin /Sessions did not return a list")
	}
	var sessions []Session
	if err := json.Unmarshal(body, &sessions); err != nil {
		return nil, fmt.Errorf("decode Jellyfin /Sessions response: %w", err)
	}
	return sessions, nil
}

type mappingEntry struct {
	username   string
	observedAt time.Time
	sessionID  string
}

// MappingCache keeps recently observed Jellyfin client address mappings.
type MappingCache struct {
	TTL time.Duration

	mu      sync.Mutex
	entries map[string]mappingEntry
}

// NewMappingCache constructs a cache with the supplied mapping TTL.
func NewMappingCache(ttl time.Duration) *MappingCache {
	return &MappingCache{TTL: ttl, entries: make(map[string]mappingEntry)}
}

// ObserveSessions atomically records active playback sessions observed at now.
func (c *MappingCache) ObserveSessions(sessions []Session, now time.Time) error {
	updates := make(map[string]mappingEntry)
	for _, session := range sessions {
		if !session.NowPlaying {
			continue
		}
		if session.Username == "" {
			continue
		}
		clientIP, ok := normalizeAddress(session.RemoteEndpoint)
		if !ok {
			return fmt.Errorf("Jellyfin RemoteEndPoint must be an IP address")
		}
		updates[clientIP] = mappingEntry{
			username:   session.Username,
			observedAt: now,
			sessionID:  session.ID,
		}
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]mappingEntry)
	}
	for clientIP, entry := range updates {
		c.entries[clientIP] = entry
	}
	return nil
}

// Lookup returns the mapped username for clientIP, or "unknown" when absent or expired.
func (c *MappingCache) Lookup(clientIP string, now time.Time) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[clientIP]
	if !ok {
		return "unknown"
	}
	if now.Sub(entry.observedAt) > c.TTL {
		delete(c.entries, clientIP)
		return "unknown"
	}
	return entry.username
}

// ActiveCount removes expired mappings and returns the number still active.
func (c *MappingCache) ActiveCount(now time.Time) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	for clientIP, entry := range c.entries {
		if now.Sub(entry.observedAt) > c.TTL {
			delete(c.entries, clientIP)
		}
	}
	return len(c.entries)
}

func normalizeAddress(value string) (string, bool) {
	candidate := strings.TrimSpace(value)
	if candidate == "" {
		return "", false
	}

	if strings.HasPrefix(candidate, "[") {
		close := strings.Index(candidate, "]")
		if close == -1 {
			return "", false
		}
		suffix := candidate[close+1:]
		if suffix != "" {
			host, port, err := net.SplitHostPort(candidate)
			if err != nil || host != candidate[1:close] || !decimalPort(port) {
				return "", false
			}
		}
		candidate = candidate[1:close]
	} else if _, err := netip.ParseAddr(candidate); err != nil {
		host, port, splitErr := net.SplitHostPort(candidate)
		if splitErr != nil || !decimalPort(port) {
			return "", false
		}
		candidate = host
	}

	address, err := netip.ParseAddr(candidate)
	if err != nil {
		return "", false
	}
	return address.Unmap().String(), true
}

func decimalPort(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}
