package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
)

const checkpointAnchorBytes int64 = 64

// Checkpoint records the position and content fingerprint of an access log.
type Checkpoint struct {
	Inode  uint64
	Offset int64
	Anchor *string
}

// LoadCheckpoint returns nil for a missing or structurally invalid checkpoint.
func LoadCheckpoint(path string) (*Checkpoint, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read checkpoint: %w", err)
	}

	var value map[string]json.RawMessage
	if err := json.Unmarshal(contents, &value); err != nil || value == nil {
		return nil, nil
	}
	inode, ok := checkpointUint(value["inode"])
	if !ok {
		return nil, nil
	}
	offset, ok := checkpointOffset(value["offset"])
	if !ok {
		return nil, nil
	}
	anchor, ok := checkpointAnchor(value["anchor"])
	if !ok {
		return nil, nil
	}
	return &Checkpoint{Inode: inode, Offset: offset, Anchor: anchor}, nil
}

func checkpointUint(raw json.RawMessage) (uint64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	value, err := strconv.ParseUint(string(raw), 10, 64)
	return value, err == nil
}

func checkpointOffset(raw json.RawMessage) (int64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	value, err := strconv.ParseInt(string(raw), 10, 64)
	return value, err == nil && value >= 0
}

func checkpointAnchor(raw json.RawMessage) (*string, bool) {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return nil, true
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, false
	}
	return &value, true
}

// SaveCheckpoint atomically replaces path with checkpoint JSON.
func SaveCheckpoint(path string, checkpoint Checkpoint) error {
	if checkpoint.Offset < 0 {
		return fmt.Errorf("checkpoint offset must be non-negative")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create checkpoint directory: %w", err)
	}

	contents, err := json.Marshal(struct {
		Inode  uint64  `json:"inode"`
		Offset int64   `json:"offset"`
		Anchor *string `json:"anchor"`
	}{
		Inode: checkpoint.Inode, Offset: checkpoint.Offset, Anchor: checkpoint.Anchor,
	})
	if err != nil {
		return fmt.Errorf("encode checkpoint: %w", err)
	}

	temporary := path + ".tmp"
	cleanupTemporary := true
	defer func() {
		if cleanupTemporary {
			_ = os.Remove(temporary)
		}
	}()

	handle, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("open temporary checkpoint: %w", err)
	}
	if _, err := handle.Write(contents); err != nil {
		_ = handle.Close()
		return fmt.Errorf("write temporary checkpoint: %w", err)
	}
	if err := handle.Close(); err != nil {
		return fmt.Errorf("close temporary checkpoint: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		return fmt.Errorf("replace checkpoint: %w", err)
	}
	cleanupTemporary = false
	return nil
}

// CheckpointAnchor returns the SHA-256 of at most 64 bytes ending at offset.
func CheckpointAnchor(handle *os.File, offset int64) (anchor string, err error) {
	if offset < 0 {
		return "", fmt.Errorf("checkpoint offset must be non-negative")
	}
	position, err := handle.Seek(0, io.SeekCurrent)
	if err != nil {
		return "", fmt.Errorf("read checkpoint cursor: %w", err)
	}
	defer func() {
		if _, restoreErr := handle.Seek(position, io.SeekStart); restoreErr != nil && err == nil {
			err = fmt.Errorf("restore checkpoint cursor: %w", restoreErr)
		}
	}()

	start := offset - checkpointAnchorBytes
	if start < 0 {
		start = 0
	}
	if _, err := handle.Seek(start, io.SeekStart); err != nil {
		return "", fmt.Errorf("seek checkpoint anchor: %w", err)
	}
	contents := make([]byte, offset-start)
	read, readErr := io.ReadFull(handle, contents)
	if readErr != nil && readErr != io.EOF && readErr != io.ErrUnexpectedEOF {
		return "", fmt.Errorf("read checkpoint anchor: %w", readErr)
	}
	digest := sha256.Sum256(contents[:read])
	return hex.EncodeToString(digest[:]), nil
}
