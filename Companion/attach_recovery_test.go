package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestAttachDoneOnlyStopsForConfirmedTerminalState(t *testing.T) {
	for _, tc := range []struct {
		name, exec, box string
		status          int
		timeout, done   bool
	}{
		{"running", `{"status":"running","tty":true}`, `{"runtime":{"runtimeState":"running"}}`, 200, false, false},
		{"temporary proxy failure", `{}`, `{"runtime":{"runtimeState":"running"}}`, 503, false, false},
		{"temporary metadata timeout", `{}`, `{"runtime":{"runtimeState":"running"}}`, 200, true, false},
		{"cached running while recovering", `{"status":"running","observedAt":"saved"}`, `{"runtime":{"runtimeState":"running"}}`, 200, false, false},
		{"repair underway", `{}`, `{"runtime":{"state":"failed","runtimeState":"stopped","displayState":"repairing"}}`, 503, false, false},
		{"confirmed stop", `{}`, `{"runtime":{"runtimeState":"stopped"}}`, 503, false, true},
		{"confirmed suspension", `{}`, `{"runtime":{"runtimeState":"suspended"}}`, 503, false, true},
		{"confirmed failure", `{}`, `{"runtime":{"state":"failed"}}`, 503, false, true},
		{"permission revoked", `{}`, `{}`, 403, false, true},
		{"missing route during restart", `{}`, `{"runtime":{"runtimeState":"running"}}`, 404, false, false},
		{"exec exited", `{"status":"exited"}`, `{}`, 200, false, true},
		{"exec failed", `{"status":"failed"}`, `{}`, 200, false, true},
		{"concrete exec lost", `{"status":"lost"}`, `{}`, 200, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := &bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
				if r.Method != "GET" {
					t.Fatalf("recovery attempted a mutation: %s", r.Method)
				}
				if strings.Contains(r.URL.Path, "/execs/") {
					if tc.timeout {
						return nil, context.DeadlineExceeded
					}
					res := reply(tc.exec)
					res.StatusCode = tc.status
					return res, nil
				}
				return reply(tc.box), nil
			})}}
			done, _ := b.attachDone(t.Context(), request{ProjectID: "p", SandboxID: "b", ExecID: "e"})
			if done != tc.done {
				t.Fatalf("done=%v, want %v", done, tc.done)
			}
		})
	}
}

func TestAttachStatusIsPrivateNonblockingAndRejectsRegularFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	reader, err := syscall.Open(path, syscall.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(reader)
	emit, closeWriter := attachStatusWriter(path)
	defer closeWriter()
	emit("reconnecting", "")
	var buf [4096]byte
	n, err := syscall.Read(reader, buf[:])
	if err != nil || !strings.Contains(string(buf[:n]), `"state":"reconnecting"`) {
		t.Fatalf("missing status: %q %v", buf[:n], err)
	}
	// A full status pipe must never stall terminal reconnection callbacks.
	for i := 0; i < 10000; i++ {
		emit("reconnecting", "")
	}
	regular := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(regular, []byte("untouched"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{regular, regular + "-link"} {
		if target != regular {
			if err := os.Symlink(regular, target); err != nil {
				t.Fatal(err)
			}
		}
		write, close := attachStatusWriter(target)
		write("connected", "")
		close()
	}
	data, err := os.ReadFile(regular)
	if err != nil || string(data) != "untouched" {
		t.Fatal("status channel modified a regular file")
	}
	if _, err = syscall.Read(reader, buf[:]); err != nil && !errors.Is(err, syscall.EAGAIN) {
		t.Fatal(err)
	}
}
