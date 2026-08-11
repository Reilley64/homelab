package agent

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoadCheckpointLoadsLegacyAndAnchoredData(t *testing.T) {
	t.Parallel()

	t.Run("legacy without anchor", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "checkpoint.json")
		if err := os.WriteFile(path, []byte(`{"inode":123,"offset":456}`), 0o644); err != nil {
			t.Fatalf("WriteFile() error = %v", err)
		}

		checkpoint, err := LoadCheckpoint(path)
		if err != nil {
			t.Fatalf("LoadCheckpoint() error = %v", err)
		}
		want := &Checkpoint{Inode: 123, Offset: 456}
		if !reflect.DeepEqual(checkpoint, want) {
			t.Errorf("LoadCheckpoint() = %#v, want %#v", checkpoint, want)
		}
	})

	t.Run("complete anchored data", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "checkpoint.json")
		anchor := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		if err := os.WriteFile(path, []byte(`{"inode":123,"offset":456,"anchor":"`+anchor+`"}`), 0o644); err != nil {
			t.Fatalf("WriteFile() error = %v", err)
		}

		checkpoint, err := LoadCheckpoint(path)
		if err != nil {
			t.Fatalf("LoadCheckpoint() error = %v", err)
		}
		want := &Checkpoint{Inode: 123, Offset: 456, Anchor: &anchor}
		if !reflect.DeepEqual(checkpoint, want) {
			t.Errorf("LoadCheckpoint() = %#v, want %#v", checkpoint, want)
		}
	})
}

func TestLoadCheckpointTreatsMissingAndInvalidStructureAsAbsent(t *testing.T) {
	t.Parallel()

	missing, err := LoadCheckpoint(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatalf("LoadCheckpoint(missing) error = %v", err)
	}
	if missing != nil {
		t.Errorf("LoadCheckpoint(missing) = %#v, want nil", missing)
	}

	for _, contents := range []string{
		`[]`,
		`null`,
		`{}`,
		`{"inode":-1,"offset":1}`,
		`{"inode":1,"offset":-1}`,
		`{"inode":1,"offset":1,"anchor":123}`,
		`not json`,
	} {
		t.Run(contents, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "checkpoint.json")
			if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
				t.Fatalf("WriteFile() error = %v", err)
			}
			checkpoint, err := LoadCheckpoint(path)
			if err != nil {
				t.Fatalf("LoadCheckpoint() error = %v, want invalid checkpoint treated as absent", err)
			}
			if checkpoint != nil {
				t.Errorf("LoadCheckpoint() = %#v, want nil", checkpoint)
			}
		})
	}
}

func TestLoadCheckpointReturnsReadErrors(t *testing.T) {
	t.Parallel()

	_, err := LoadCheckpoint(t.TempDir())
	if err == nil {
		t.Fatal("LoadCheckpoint(directory) error = nil, want read error")
	}
}

func TestCheckpointAnchorHashesLastSixtyFourBytesAndPreservesCursor(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "access.json")
	contents := []byte("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ--suffix")
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	handle, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	defer handle.Close()
	if _, err := handle.Seek(3, 0); err != nil {
		t.Fatalf("Seek() error = %v", err)
	}

	anchor, err := CheckpointAnchor(handle, int64(len(contents)))
	if err != nil {
		t.Fatalf("CheckpointAnchor() error = %v", err)
	}
	if anchor != "e072a8645d0ddb879ce9d195fd304ca80fe4251949458f81f83168234c2aca01" {
		t.Errorf("CheckpointAnchor() = %q, want SHA-256 of last 64 bytes", anchor)
	}
	if position, err := handle.Seek(0, 1); err != nil || position != 3 {
		t.Errorf("cursor after CheckpointAnchor() = %d, %v; want 3, nil", position, err)
	}
}

func TestSaveCheckpointCreatesParentsAndAtomicallyReplacesDestination(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "nested", "state", "checkpoint.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(path, []byte(`{"inode":1,"offset":2}`), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	anchor := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if err := SaveCheckpoint(path, Checkpoint{Inode: 123, Offset: 456, Anchor: &anchor}); err != nil {
		t.Fatalf("SaveCheckpoint() error = %v", err)
	}

	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	var saved map[string]any
	if err := json.Unmarshal(contents, &saved); err != nil {
		t.Fatalf("saved checkpoint is not JSON: %v", err)
	}
	if got, want := saved["inode"], float64(123); got != want {
		t.Errorf("saved inode = %#v, want %#v", got, want)
	}
	if got, want := saved["offset"], float64(456); got != want {
		t.Errorf("saved offset = %#v, want %#v", got, want)
	}
	if got, want := saved["anchor"], anchor; got != want {
		t.Errorf("saved anchor = %#v, want %#v", got, want)
	}
	if _, err := os.Stat(path + ".tmp"); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("temporary checkpoint file remains: %v", err)
	}
}

func TestSaveCheckpointCreatesMissingParentDirectories(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "nested", "state", "checkpoint.json")
	if err := SaveCheckpoint(path, Checkpoint{Inode: 1, Offset: 2}); err != nil {
		t.Fatalf("SaveCheckpoint() error = %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("saved checkpoint stat error = %v", err)
	}
}
