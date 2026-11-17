package terminal

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/creack/pty"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/host"
)

type latencyReplay struct{}

func (*latencyReplay) Observe([]byte)   {}
func (*latencyReplay) Snapshot() []byte { return []byte("READY\n") }
func (*latencyReplay) AfterReplay()     {}

// Exercise the production controlling-PTY, input pump, resumable WebSocket,
// output queue and PTY writer together. Every byte arrives after an idle gap
// and must echo without a newline or another keystroke to flush it.
func TestTerminalInputRoundTripWithoutNewline(t *testing.T) {
	if address := os.Getenv("DISCOBOX_TEST_LATENCY_ENDPOINT"); address != "" {
		defer diagnostics.StartWithSink(diagnostics.Event{}, func([]byte) error { return nil })()
		if err := Attach(address, wire.Request{ProjectID: "p", SandboxID: "b", ExecID: "e"}, ""); err != nil {
			t.Fatal(err)
		}
		return
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var stream *host.Stream
	received := 0
	stream = host.New(host.Options{Done: ctx.Done(), OnFrame: func(f frame.Frame) error {
		if f.Type == frame.Input {
			received += len(f.Payload)
			stream.Broadcast(frame.Stdout, f.Payload)
			if received == 100 {
				stream.Broadcast(frame.Exit, nil)
			}
		} else if f.Type != frame.Resize {
			t.Errorf("unexpected action %d", f.Type)
		}
		return nil
	}})
	stream.SetReplayer(&latencyReplay{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Error("unexpected mutation")
			http.Error(w, "no", 405)
			return
		}
		switch r.URL.Path {
		case "/projects/p/sandboxes/b":
			io.WriteString(w, `{"runtime":{"runtimeState":"running"}}`)
		case "/api/projects/p/sandboxes/b/execs/e":
			io.WriteString(w, `{"status":"running","tty":true}`)
		case "/api/projects/p/sandboxes/b/execs/e/attach":
			ws, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			defer ws.CloseNow()
			_ = stream.Attach(ctx, &attachFrames{Conn: websocket.NetConn(ctx, ws, websocket.MessageBinary)}, host.AttachOptions{Replay: true})
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cmd := exec.Command(os.Args[0], "-test.run=^TestTerminalInputRoundTripWithoutNewline$")
	cmd.Env = append(os.Environ(), "DISCOBOX_TEST_LATENCY_ENDPOINT="+server.URL)
	tty, err := pty.Start(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer tty.Close()
	defer func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	}()
	timer := time.AfterFunc(7*time.Second, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	r := bufio.NewReader(tty)
	line, err := r.ReadString('\n')
	if err != nil || !strings.HasSuffix(line, "READY\n") {
		t.Fatalf("startup %q %v", line, err)
	}
	times := make([]time.Duration, 0, 100)
	for i := 0; i < 100; i++ {
		time.Sleep(time.Millisecond * 3)
		start := time.Now()
		if _, err = tty.Write([]byte{'x'}); err != nil {
			t.Fatal(err)
		}
		b, err := r.ReadByte()
		if err != nil || b != 'x' {
			t.Fatalf("echo %q %v", b, err)
		}
		times = append(times, time.Since(start))
	}
	out, _ := io.ReadAll(r)
	if err = cmd.Wait(); err != nil {
		t.Fatalf("child %v %s", err, out)
	}
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	t.Logf("PTY/WebSocket roundtrip p50=%s p95=%s max=%s", times[50], times[95], times[99])
}
