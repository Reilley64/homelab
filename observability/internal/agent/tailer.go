package agent

import (
	"fmt"
	"io"
	"os"
	"sync"
	"syscall"
	"time"
)

const (
	attributionDelay = 30 * time.Second
	maxFutureSkew    = 5 * time.Second
)

// Tailer processes completed Traefik access-log records after their mappings
// have had time to arrive from Jellyfin.
type Tailer struct {
	LogPath        string
	CheckpointPath string
	Cache          *MappingCache
	Metrics        *MetricState
	FileMu         *sync.Mutex
}

// ProcessAvailable processes complete, checkpointed access-log records that
// are available at now. It returns the number of valid Jellyfin events applied.
func (t *Tailer) ProcessAvailable(now time.Time) (int, error) {
	if t.FileMu != nil {
		t.FileMu.Lock()
		defer t.FileMu.Unlock()
	}

	handle, err := os.Open(t.LogPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, fmt.Errorf("open access log: %w", err)
	}
	defer handle.Close()

	info, err := handle.Stat()
	if err != nil {
		return 0, fmt.Errorf("stat access log: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("access log stat has unexpected type %T", info.Sys())
	}

	startOffset, err := t.startOffset(handle, uint64(stat.Ino), info.Size())
	if err != nil {
		return 0, err
	}
	if _, err := handle.Seek(startOffset, io.SeekStart); err != nil {
		return 0, fmt.Errorf("seek access log: %w", err)
	}

	processed := 0
	for {
		lineStart, err := handle.Seek(0, io.SeekCurrent)
		if err != nil {
			return processed, fmt.Errorf("read access log cursor: %w", err)
		}
		line, err := readLine(handle)
		if err != nil {
			return processed, err
		}
		if line == nil {
			break
		}
		if len(line) == 0 || line[len(line)-1] != '\n' {
			if _, err := handle.Seek(lineStart, io.SeekStart); err != nil {
				return processed, fmt.Errorf("rewind incomplete access log line: %w", err)
			}
			break
		}

		event, parseErr := ParseAccessLine(line)
		if parseErr != nil {
			t.incrementAccessLogErrors()
		} else if event != nil {
			age := now.Sub(event.RecordedAt)
			if age < -maxFutureSkew {
				t.incrementAccessLogErrors()
			} else {
				if age < 0 {
					age = 0
				}
				username := t.lookup(event.ClientIP, now)
				if username == "unknown" && age < attributionDelay {
					if _, err := handle.Seek(lineStart, io.SeekStart); err != nil {
						return processed, fmt.Errorf("rewind deferred access log line: %w", err)
					}
					break
				}
				t.apply(*event, username)
				processed++
			}
		}

		offset, err := handle.Seek(0, io.SeekCurrent)
		if err != nil {
			return processed, fmt.Errorf("read access log cursor: %w", err)
		}
		if err := t.saveCheckpoint(handle, uint64(stat.Ino), offset); err != nil {
			return processed, err
		}
	}
	return processed, nil
}

func (t *Tailer) startOffset(handle *os.File, inode uint64, size int64) (int64, error) {
	checkpoint, err := LoadCheckpoint(t.CheckpointPath)
	if err != nil {
		return 0, err
	}
	if checkpoint == nil {
		startOffset, err := firstStartOffset(handle, size)
		if err != nil {
			return 0, err
		}
		if err := t.saveCheckpoint(handle, inode, startOffset); err != nil {
			return 0, err
		}
		return startOffset, nil
	}

	anchorMatches := false
	if checkpoint.Inode == inode && checkpoint.Offset <= size && checkpoint.Anchor != nil {
		anchor, err := CheckpointAnchor(handle, checkpoint.Offset)
		if err != nil {
			return 0, err
		}
		anchorMatches = anchor == *checkpoint.Anchor
	}
	if anchorMatches {
		return checkpoint.Offset, nil
	}

	t.incrementCheckpointDiscontinuities()
	if err := t.saveCheckpoint(handle, inode, 0); err != nil {
		return 0, err
	}
	return 0, nil
}

func firstStartOffset(handle *os.File, size int64) (int64, error) {
	if _, err := handle.Seek(0, io.SeekStart); err != nil {
		return 0, fmt.Errorf("seek access log start: %w", err)
	}
	for {
		lineStart, err := handle.Seek(0, io.SeekCurrent)
		if err != nil {
			return 0, fmt.Errorf("read access log cursor: %w", err)
		}
		line, err := readLine(handle)
		if err != nil {
			return 0, err
		}
		if line == nil {
			return size, nil
		}
		if line[len(line)-1] != '\n' {
			return lineStart, nil
		}
	}
}

func (t *Tailer) saveCheckpoint(handle *os.File, inode uint64, offset int64) error {
	anchor, err := CheckpointAnchor(handle, offset)
	if err != nil {
		return err
	}
	if err := SaveCheckpoint(t.CheckpointPath, Checkpoint{Inode: inode, Offset: offset, Anchor: &anchor}); err != nil {
		return err
	}
	return nil
}

func readLine(handle *os.File) ([]byte, error) {
	var line []byte
	buffer := make([]byte, 4096)
	for {
		read, err := handle.Read(buffer)
		if read > 0 {
			line = append(line, buffer[:read]...)
			for index, value := range line {
				if value == '\n' {
					extra := int64(len(line) - index - 1)
					if extra > 0 {
						if _, seekErr := handle.Seek(-extra, io.SeekCurrent); seekErr != nil {
							return nil, fmt.Errorf("rewind access log read-ahead: %w", seekErr)
						}
					}
					return line[:index+1], nil
				}
			}
		}
		if err == io.EOF {
			if len(line) == 0 {
				return nil, nil
			}
			return line, nil
		}
		if err != nil {
			return nil, fmt.Errorf("read access log: %w", err)
		}
	}
}

func (t *Tailer) lookup(clientIP string, now time.Time) string {
	if t.Cache == nil {
		return "unknown"
	}
	return t.Cache.Lookup(clientIP, now)
}

func (t *Tailer) apply(event AccessEvent, username string) {
	if t.Metrics != nil {
		t.Metrics.Apply(event, username)
	}
}

func (t *Tailer) incrementAccessLogErrors() {
	if t.Metrics != nil {
		t.Metrics.IncrementAccessLogErrors()
	}
}

func (t *Tailer) incrementCheckpointDiscontinuities() {
	if t.Metrics != nil {
		t.Metrics.IncrementCheckpointDiscontinuities()
	}
}
