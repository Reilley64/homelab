package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestTailerResumeProcessesEachLineOnce(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 100, 0)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	cache := NewMappingCache(time.Hour)
	if err := cache.ObserveSessions([]Session{{Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true}}, time.Unix(1000, 0)); err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	tailer := newTailer(paths, cache)

	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 1 {
		t.Fatalf("first ProcessAvailable() = %d, %v; want 1, nil", processed, err)
	}
	if processed, err := tailer.ProcessAvailable(time.Unix(1002, 0)); err != nil || processed != 0 {
		t.Fatalf("second ProcessAvailable() = %d, %v; want 0, nil", processed, err)
	}
	if got := tailer.Metrics.Render(1); !strings.Contains(got, `user="alice",client_ip="203.0.113.8"} 100`) {
		t.Errorf("attributed metrics missing once-processed record:\n%s", got)
	}
}

func TestTailerMissingLogDoesNothing(t *testing.T) {
	paths := newTailerPaths(t)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 0, nil for missing log", processed, err)
	}
	if _, err := os.Stat(paths.checkpoint); !os.IsNotExist(err) {
		t.Errorf("checkpoint stat error = %v; want missing checkpoint", err)
	}
}

func TestTailerFirstStartSkipsExistingLines(t *testing.T) {
	paths := newTailerPaths(t)
	line := tailerLine(t, "203.0.113.8", 25, 0)
	writeTailerLog(t, paths.log, line+"\n")
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 0 {
		t.Fatalf("first ProcessAvailable() = %d, %v; want 0, nil", processed, err)
	}
	appendTailerLog(t, paths.log, line+"\n")
	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() after append = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_checkpoint_discontinuities_total 0") {
		t.Errorf("first start registered a discontinuity:\n%s", got)
	}
}

func TestTailerCopyTruncateRestartsAtZero(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, strings.Repeat("x", 512)+"\n")
	tailer := newTailer(paths, NewMappingCache(time.Hour))
	if _, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil {
		t.Fatalf("initial ProcessAvailable() error = %v", err)
	}
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 0)+"\n")

	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_checkpoint_discontinuities_total 1") {
		t.Errorf("copy-truncate was not recorded:\n%s", got)
	}
}

func TestTailerCopyTruncateRegrowthBeyondSavedOffsetRestarts(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, strings.Repeat("x", 512)+"\n")
	tailer := newTailer(paths, NewMappingCache(time.Hour))
	if _, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil {
		t.Fatalf("initial ProcessAvailable() error = %v", err)
	}
	regrown := tailerLine(t, "203.0.113.8", 25, 0) + "\n" + strings.Repeat(`{"RouterName":"traefik@docker"}`+"\n", 32)
	writeTailerLog(t, paths.log, regrown)

	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_checkpoint_discontinuities_total 1") {
		t.Errorf("regrown copy-truncate was not recorded:\n%s", got)
	}
}

func TestTailerLegacyCheckpointRestartsConservatively(t *testing.T) {
	paths := newTailerPaths(t)
	line := tailerLine(t, "203.0.113.8", 25, 0) + "\n"
	writeTailerLog(t, paths.log, line)
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, int64(len(line)), false)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_checkpoint_discontinuities_total 1") {
		t.Errorf("legacy checkpoint restart was not recorded:\n%s", got)
	}
}

func TestTailerDefersUnknownAttributionUntilDeadline(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 1000)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1029, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable(1029) = %d, %v; want 0, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset != 0 {
		t.Fatalf("checkpoint after deferral = %#v, %v; want offset 0", checkpoint, err)
	}
	if processed, err := tailer.ProcessAvailable(time.Unix(1030, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable(1030) = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_unattributed_bytes_total 25") {
		t.Errorf("deadline did not attribute bytes as unknown:\n%s", got)
	}
}

func TestTailerDefersSmallFutureSkew(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 1005)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 0, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset != 0 {
		t.Fatalf("checkpoint after future skew = %#v, %v; want offset 0", checkpoint, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_access_log_errors_total 0") {
		t.Errorf("allowed future skew was counted as an error:\n%s", got)
	}
}

func TestTailerCountsTimestampBeyondFutureSkewAsAccessError(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 1006)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 0, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset == 0 {
		t.Fatalf("checkpoint after invalid timestamp = %#v, %v; want consumed line", checkpoint, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_access_log_errors_total 1") {
		t.Errorf("future timestamp was not counted as an access error:\n%s", got)
	}
}

func TestTailerUsesMappingThatArrivesDuringDeferral(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.8", 25, 1000)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	cache := NewMappingCache(time.Hour)
	tailer := newTailer(paths, cache)
	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() before mapping = %d, %v; want 0, nil", processed, err)
	}
	if err := cache.ObserveSessions([]Session{{Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true}}, time.Unix(1001, 0)); err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	if processed, err := tailer.ProcessAvailable(time.Unix(1002, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() after mapping = %d, %v; want 1, nil", processed, err)
	}
	if got := tailer.Metrics.Render(1); !strings.Contains(got, `user="alice",client_ip="203.0.113.8"} 25`) {
		t.Errorf("deferred event was not attributed to arriving mapping:\n%s", got)
	}
}

func TestTailerDeferredLineBlocksFollowingLines(t *testing.T) {
	paths := newTailerPaths(t)
	writeTailerLog(t, paths.log, tailerLine(t, "203.0.113.9", 10, 1000)+"\n"+tailerLine(t, "203.0.113.8", 20, 1000)+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	cache := NewMappingCache(time.Hour)
	if err := cache.ObserveSessions([]Session{{Username: "alice", RemoteEndpoint: "203.0.113.8", NowPlaying: true}}, time.Unix(1000, 0)); err != nil {
		t.Fatalf("ObserveSessions() error = %v", err)
	}
	tailer := newTailer(paths, cache)

	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() during deferral = %d, %v; want 0, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset != 0 {
		t.Fatalf("checkpoint during ordered deferral = %#v, %v; want offset 0", checkpoint, err)
	}
	if processed, err := tailer.ProcessAvailable(time.Unix(1030, 0)); err != nil || processed != 2 {
		t.Fatalf("ProcessAvailable() after deadline = %d, %v; want 2, nil", processed, err)
	}
}

func TestTailerCheckpointsMalformedCompleteLinesAndContinues(t *testing.T) {
	paths := newTailerPaths(t)
	valid := tailerLine(t, "203.0.113.8", 10, 0)
	writeTailerLog(t, paths.log, "not-json\n"+valid+"\n")
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() = %d, %v; want 1, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset != int64(len("not-json\n"+valid+"\n")) {
		t.Fatalf("checkpoint after malformed record = %#v, %v; want end of file", checkpoint, err)
	}
	if got := tailer.Metrics.Render(0); !strings.Contains(got, "jellyfin_egress_access_log_errors_total 1") {
		t.Errorf("malformed record was not counted as an access error:\n%s", got)
	}
}

func TestTailerRetriesInitiallyUnterminatedRecord(t *testing.T) {
	paths := newTailerPaths(t)
	partial := `{"RouterName":"jellyfin@docker","ClientHost":"203.0.113.8",`
	writeTailerLog(t, paths.log, partial)
	saveTailerCheckpoint(t, paths.log, paths.checkpoint, 0, true)
	tailer := newTailer(paths, NewMappingCache(time.Hour))

	if processed, err := tailer.ProcessAvailable(time.Unix(1000, 0)); err != nil || processed != 0 {
		t.Fatalf("ProcessAvailable() before completion = %d, %v; want 0, nil", processed, err)
	}
	checkpoint, err := LoadCheckpoint(paths.checkpoint)
	if err != nil || checkpoint == nil || checkpoint.Offset != 0 {
		t.Fatalf("checkpoint after unterminated record = %#v, %v; want offset 0", checkpoint, err)
	}
	appendTailerLog(t, paths.log, `"DownstreamContentSize":7,"time":"1970-01-01T00:00:00Z"}`+"\n")
	if processed, err := tailer.ProcessAvailable(time.Unix(1001, 0)); err != nil || processed != 1 {
		t.Fatalf("ProcessAvailable() after completion = %d, %v; want 1, nil", processed, err)
	}
}

type tailerPaths struct {
	log        string
	checkpoint string
}

func newTailerPaths(t *testing.T) tailerPaths {
	t.Helper()
	directory := t.TempDir()
	return tailerPaths{log: filepath.Join(directory, "access.json"), checkpoint: filepath.Join(directory, "checkpoint.json")}
}

func newTailer(paths tailerPaths, cache *MappingCache) *Tailer {
	return &Tailer{LogPath: paths.log, CheckpointPath: paths.checkpoint, Cache: cache, Metrics: &MetricState{}, FileMu: &sync.Mutex{}}
}

func tailerLine(t *testing.T, clientIP string, bytes int64, unixSeconds int64) string {
	t.Helper()
	contents, err := json.Marshal(map[string]any{
		"RouterName":            "jellyfin@docker",
		"ClientHost":            clientIP,
		"DownstreamContentSize": bytes,
		"time":                  time.Unix(unixSeconds, 0).UTC().Format(time.RFC3339),
	})
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}
	return string(contents)
}

func writeTailerLog(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func appendTailerLog(t *testing.T, path, contents string) {
	t.Helper()
	handle, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("OpenFile(%s) error = %v", path, err)
	}
	defer handle.Close()
	if _, err := handle.WriteString(contents); err != nil {
		t.Fatalf("WriteString(%s) error = %v", path, err)
	}
}

func saveTailerCheckpoint(t *testing.T, logPath, checkpointPath string, offset int64, anchored bool) {
	t.Helper()
	handle, err := os.Open(logPath)
	if err != nil {
		t.Fatalf("Open(%s) error = %v", logPath, err)
	}
	defer handle.Close()
	stat, err := handle.Stat()
	if err != nil {
		t.Fatalf("Stat(%s) error = %v", logPath, err)
	}
	systemStat, ok := stat.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("Stat(%s).Sys() = %T, want *syscall.Stat_t", logPath, stat.Sys())
	}
	checkpoint := Checkpoint{Inode: systemStat.Ino, Offset: offset}
	if anchored {
		anchor, err := CheckpointAnchor(handle, offset)
		if err != nil {
			t.Fatalf("CheckpointAnchor() error = %v", err)
		}
		checkpoint.Anchor = &anchor
	}
	if err := SaveCheckpoint(checkpointPath, checkpoint); err != nil {
		t.Fatalf("SaveCheckpoint() error = %v", err)
	}
}
