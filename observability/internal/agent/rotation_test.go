package agent

import (
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestRotatorMissingLogDoesNotRotate(t *testing.T) {
	rotator := Rotator{Path: filepath.Join(t.TempDir(), "missing.log"), MaxBytes: 1}

	rotated, err := rotator.RotateIfNeeded()
	if err != nil {
		t.Fatalf("RotateIfNeeded() error = %v", err)
	}
	if rotated {
		t.Fatal("RotateIfNeeded() rotated missing log")
	}
}

func TestRotatorBelowThresholdDoesNotRotate(t *testing.T) {
	path := writeRotationLog(t, "abc")
	rotator := Rotator{Path: path, MaxBytes: 4}

	rotated, err := rotator.RotateIfNeeded()
	if err != nil {
		t.Fatalf("RotateIfNeeded() error = %v", err)
	}
	if rotated {
		t.Fatal("RotateIfNeeded() rotated below threshold")
	}
	if got := readRotationFile(t, path); got != "abc" {
		t.Fatalf("active log = %q, want %q", got, "abc")
	}
}

func TestRotatorAtThresholdCompressesAndTruncatesSameInode(t *testing.T) {
	path := writeRotationLog(t, "abcd")
	inode := rotationInode(t, path)
	rotator := Rotator{Path: path, MaxBytes: 4, Copies: 2}

	rotated, err := rotator.RotateIfNeeded()
	if err != nil {
		t.Fatalf("RotateIfNeeded() error = %v", err)
	}
	if !rotated {
		t.Fatal("RotateIfNeeded() did not rotate at threshold")
	}
	if got := readRotationGzip(t, path+".1.gz"); got != "abcd" {
		t.Fatalf("first rotated copy = %q, want %q", got, "abcd")
	}
	if got := readRotationFile(t, path); got != "" {
		t.Fatalf("active log = %q, want empty", got)
	}
	if got := rotationInode(t, path); got != inode {
		t.Fatalf("active log inode = %d, want %d", got, inode)
	}
}

func TestRotatorShiftsAndBoundsRetainedCopies(t *testing.T) {
	path := writeRotationLog(t, "one")
	rotator := Rotator{Path: path, MaxBytes: 1, Copies: 2}

	for _, contents := range []string{"one", "two", "three"} {
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", path, err)
		}
		rotated, err := rotator.RotateIfNeeded()
		if err != nil {
			t.Fatalf("RotateIfNeeded() error = %v", err)
		}
		if !rotated {
			t.Fatalf("RotateIfNeeded() did not rotate %q", contents)
		}
	}

	if got := readRotationGzip(t, path+".1.gz"); got != "three" {
		t.Fatalf("newest retained copy = %q, want %q", got, "three")
	}
	if got := readRotationGzip(t, path+".2.gz"); got != "two" {
		t.Fatalf("oldest retained copy = %q, want %q", got, "two")
	}
	if _, err := os.Stat(path + ".3.gz"); !os.IsNotExist(err) {
		t.Fatalf("third retained copy stat error = %v, want not exist", err)
	}
}

func TestRotatorPropagatesRotationIOFailure(t *testing.T) {
	path := writeRotationLog(t, "abcd")
	if err := os.Mkdir(path+".1.gz", 0o755); err != nil {
		t.Fatalf("Mkdir(%s) error = %v", path+".1.gz", err)
	}
	if err := os.WriteFile(filepath.Join(path+".1.gz", "block-removal"), []byte("x"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", filepath.Join(path+".1.gz", "block-removal"), err)
	}
	rotator := Rotator{Path: path, MaxBytes: 4, Copies: 1}

	rotated, err := rotator.RotateIfNeeded()
	if err == nil {
		t.Fatal("RotateIfNeeded() error = nil, want rotation I/O failure")
	}
	if rotated {
		t.Fatal("RotateIfNeeded() rotated despite rotation I/O failure")
	}
}

func TestTailerAndRotatorCoordinate(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 0)+"\n")
	fileMu := &sync.Mutex{}
	tailer := newTailer(paths, NewMappingCache(time.Hour))
	tailer.FileMu = fileMu
	rotator := Rotator{Path: paths.log, MaxBytes: 1, Copies: 1, FileMu: fileMu}

	fileMu.Lock()
	tailerStarted := make(chan struct{})
	rotatorStarted := make(chan struct{})
	tailerDone := make(chan error, 1)
	rotatorDone := make(chan error, 1)
	go func() {
		close(tailerStarted)
		_, err := tailer.ProcessAvailable(time.Unix(100, 0))
		tailerDone <- err
	}()
	go func() {
		close(rotatorStarted)
		_, err := rotator.RotateIfNeeded()
		rotatorDone <- err
	}()
	<-tailerStarted
	<-rotatorStarted

	if got := readRotationFile(t, paths.log); got == "" {
		t.Fatal("rotation entered file work while shared mutex was locked")
	}
	if _, err := os.Stat(paths.checkpoint); !os.IsNotExist(err) {
		t.Fatalf("tailer entered file work while shared mutex was locked: checkpoint stat error = %v", err)
	}
	select {
	case err := <-tailerDone:
		t.Fatalf("tailer completed while shared mutex was locked: %v", err)
	default:
	}
	select {
	case err := <-rotatorDone:
		t.Fatalf("rotator completed while shared mutex was locked: %v", err)
	default:
	}

	fileMu.Unlock()
	if err := <-tailerDone; err != nil {
		t.Fatalf("tailer ProcessAvailable() error = %v", err)
	}
	if err := <-rotatorDone; err != nil {
		t.Fatalf("rotator RotateIfNeeded() error = %v", err)
	}
}

func writeRotationLog(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "access.log")
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
	return path
}

func readRotationFile(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	return string(contents)
}

func readRotationGzip(t *testing.T, path string) string {
	t.Helper()
	handle, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open(%s) error = %v", path, err)
	}
	defer handle.Close()
	reader, err := gzip.NewReader(handle)
	if err != nil {
		t.Fatalf("gzip.NewReader(%s) error = %v", path, err)
	}
	defer reader.Close()
	contents, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("ReadAll(%s) error = %v", path, err)
	}
	return string(contents)
}

func rotationInode(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat(%s) error = %v", path, err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("Stat(%s).Sys() = %T, want *syscall.Stat_t", path, info.Sys())
	}
	return uint64(stat.Ino)
}
