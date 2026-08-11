package agent

import (
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
)

// Rotator retains compressed copies of a log after copy-truncate rotation.
type Rotator struct {
	Path     string
	MaxBytes int64
	Copies   int
	FileMu   *sync.Mutex
}

// RotateIfNeeded rotates Path when its size reaches MaxBytes. It preserves the
// active file's inode so writers that already hold it can continue writing.
func (r *Rotator) RotateIfNeeded() (bool, error) {
	if r.FileMu != nil {
		r.FileMu.Lock()
		defer r.FileMu.Unlock()
	}

	info, err := os.Stat(r.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("stat rotation log: %w", err)
	}
	if info.Size() < r.MaxBytes {
		return false, nil
	}

	if err := r.shiftCopies(); err != nil {
		return false, err
	}
	if r.Copies > 0 {
		if err := gzipCopy(r.Path, r.copyPath(1)); err != nil {
			return false, err
		}
	}

	handle, err := os.OpenFile(r.Path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return false, fmt.Errorf("truncate rotation log: %w", err)
	}
	if err := handle.Close(); err != nil {
		return false, fmt.Errorf("close truncated rotation log: %w", err)
	}
	return true, nil
}

func (r *Rotator) shiftCopies() error {
	if r.Copies <= 0 {
		return nil
	}
	oldest := r.copyPath(r.Copies)
	if err := os.Remove(oldest); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove oldest rotation copy: %w", err)
	}
	for copyNumber := r.Copies - 1; copyNumber >= 1; copyNumber-- {
		source := r.copyPath(copyNumber)
		if _, err := os.Stat(source); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("stat rotation copy: %w", err)
		}
		if err := os.Rename(source, r.copyPath(copyNumber+1)); err != nil {
			return fmt.Errorf("shift rotation copy: %w", err)
		}
	}
	return nil
}

func (r *Rotator) copyPath(copyNumber int) string {
	return fmt.Sprintf("%s.%d.gz", r.Path, copyNumber)
}

func gzipCopy(sourcePath, destinationPath string) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("open rotation source: %w", err)
	}

	destination, err := os.OpenFile(destinationPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return errors.Join(fmt.Errorf("open rotation copy: %w", err), closeRotationFile(source, "rotation source"))
	}
	writer := gzip.NewWriter(destination)
	_, copyErr := io.Copy(writer, source)
	writerCloseErr := writer.Close()
	destinationCloseErr := destination.Close()
	sourceCloseErr := source.Close()
	if err := errors.Join(copyErr, writerCloseErr, destinationCloseErr, sourceCloseErr); err != nil {
		return fmt.Errorf("compress rotation log: %w", err)
	}
	return nil
}

func closeRotationFile(handle *os.File, name string) error {
	if err := handle.Close(); err != nil {
		return fmt.Errorf("close %s: %w", name, err)
	}
	return nil
}
