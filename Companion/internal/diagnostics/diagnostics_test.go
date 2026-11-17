package diagnostics

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestDiagnosticsDoNotBlockAndCountDroppedRecords(t *testing.T) {
	blocked, entered := make(chan struct{}), make(chan struct{})
	var writes atomic.Int64
	d := newDiagnosticLog(Event{}, func(p []byte) error {
		if writes.Add(1) == 1 {
			close(entered)
			<-blocked
		}
		return nil
	})
	d.emit(Event{Event: "first"})
	<-entered
	for range 10000 {
		d.emit(Event{Event: "progress"})
	}
	if d.dropped.Load() == 0 {
		t.Fatal("unbounded diagnostic queue")
	}
	done := make(chan struct{})
	go func() { d.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("blocked sink prevented close")
	}
	close(blocked)
	<-d.done
}
func TestDiagnosticRotationAndPrivateFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "logs")
	for range 100 {
		if err := appendDiagnostic(dir, []byte(strings.Repeat("a", 100)+"\n"), 256, 4); err != nil {
			t.Fatal(err)
		}
	}
	files, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 5 {
		t.Fatalf("rotation files: %d", len(files))
	}
	for _, file := range files {
		info, _ := file.Info()
		if info.Mode().Perm() != 0600 || info.Size() > 256 {
			t.Fatalf("unsafe or unbounded log: %s", file.Name())
		}
	}
	path := filepath.Join(dir, "transport.jsonl")
	os.Remove(path)
	target := filepath.Join(t.TempDir(), "private")
	os.WriteFile(target, []byte("untouched"), 0600)
	os.Symlink(target, path)
	if err := appendDiagnostic(dir, []byte("oops"), 256, 4); err == nil {
		t.Fatal("followed symlink")
	}
	got, _ := os.ReadFile(target)
	if string(got) != "untouched" {
		t.Fatal("modified symlink target")
	}
}

func TestDiagnosticsCoexistWithExistingServerLogDirectory(t *testing.T) {
	home := t.TempDir()
	shared := filepath.Join(home, "Library", "Logs", "Discobox")
	if err := os.MkdirAll(shared, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shared, 0755); err != nil {
		t.Fatal(err)
	}
	dir := diagnosticDirectory(home, "darwin")
	if err := appendDiagnostic(dir, []byte("{\"event\":\"helper_started\"}\n"), 256, 4); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(shared)
	if info.Mode().Perm() != 0755 {
		t.Fatal("changed the server's shared log directory")
	}
	info, _ = os.Stat(dir)
	if info.Mode().Perm() != 0700 {
		t.Fatal("diagnostic directory is not private")
	}
	if data, err := os.ReadFile(filepath.Join(dir, "transport.jsonl")); err != nil || !bytes.Contains(data, []byte("helper_started")) {
		t.Fatalf("diagnostic missing: %v", err)
	}
}
func TestDiagnosticsExcludeArbitraryErrorsAndIdentifiers(t *testing.T) {
	secret := "Bearer very-secret-token"
	var result []byte
	d := newDiagnosticLog(Event{Box: safeDiagnosticID(secret)}, func(p []byte) error { result = append(result, p...); return nil })
	d.emit(Event{Event: "failure", Reason: Reason(errors.New(secret))})
	d.close()
	if strings.Contains(string(result), secret) || !strings.Contains(string(result), `"reason":"failure"`) {
		t.Fatalf("unsafe diagnostic: %s", result)
	}
}

func TestNativeIrohDiagnosticsDoNotExposeStderrOrChangeStdout(t *testing.T) {
	if os.Getenv("DISCOBOX_TEST_STDERR_CAPTURE") == "1" {
		records := make(chan []byte, 8)
		transportDiagnostics = newDiagnosticLog(Event{}, func(p []byte) error { records <- append([]byte(nil), p...); return nil })
		stop := CaptureIrohStderr()
		_, err := unix.Write(2, []byte("WARN https://user:secret@remote/ credential=VERY_SECRET\n"))
		if err != nil {
			t.Fatal(err)
		}
		select {
		case data := <-records:
			if strings.Contains(string(data), "secret") || strings.Contains(string(data), "VERY_SECRET") || !strings.Contains(string(data), "warning") {
				t.Fatalf("unsafe native diagnostic: %s", data)
			}
		case <-time.After(time.Second):
			t.Fatal("native stderr was not captured")
		}
		stop()
		transportDiagnostics.close()
		fmt.Print("STARTUP_PROTOCOL_UNCHANGED")
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestNativeIrohDiagnosticsDoNotExposeStderrOrChangeStdout$")
	cmd.Env = append(os.Environ(), "DISCOBOX_TEST_STDERR_CAPTURE=1")
	out, err := cmd.CombinedOutput()
	if err != nil || !bytes.Contains(out, []byte("STARTUP_PROTOCOL_UNCHANGED")) || bytes.Contains(out, []byte("VERY_SECRET")) {
		t.Fatalf("stderr capture fixture: %v %s", err, out)
	}
}
