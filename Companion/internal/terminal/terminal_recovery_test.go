package terminal

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/creack/pty"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/host"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

type recoveryReplay struct{ calls atomic.Int64 }

func (*recoveryReplay) Observe([]byte) {}
func (r *recoveryReplay) Snapshot() []byte {
	if r.calls.Add(1) == 1 {
		return bytes.Repeat([]byte("blocked output "), 32768)
	}
	return []byte("\x1b[2J\x1b[HRECOVERED_SCREEN")
}
func (*recoveryReplay) AfterReplay() {}

func TestStalledPTYDetachesThenReplaysOnlyAfterConsumerResumes(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()
	fd := int(slave.Fd())
	if _, err := term.MakeRaw(fd); err != nil {
		t.Fatal(err)
	}
	if err := unix.SetNonblock(fd, true); err != nil {
		t.Fatal(err)
	}
	tty := &localTerminal{input: fd, output: fd}
	stream := host.New(host.Options{Done: ctx.Done(), OnFrame: func(f frame.Frame) error {
		if f.Type != frame.Resize {
			t.Errorf("recovery sent input or mutation: %d", f.Type)
		}
		return nil
	}})
	replay := &recoveryReplay{}
	stream.SetReplayer(replay)
	var attaches, active atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Error("recovery mutated the box")
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
			attaches.Add(1)
			active.Add(1)
			defer active.Add(-1)
			conn := &attachFrames{Conn: websocket.NetConn(ctx, ws, websocket.MessageBinary)}
			_ = stream.Attach(ctx, conn, host.AttachOptions{Replay: true})
		default:
			t.Errorf("unexpected route: %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	stalled := make(chan struct{}, 3)
	done := make(chan error, 1)
	go func() {
		done <- runTerminalRecovery(ctx, server.URL, wire.Request{ProjectID: "p", SandboxID: "b", ExecID: "e"}, tty, nil,
			func(state, _ string) {
				if state == "output-stalled" {
					stalled <- struct{}{}
				}
			}, "", true)
	}()
	select {
	case <-stalled:
	case <-ctx.Done():
		t.Fatal("PTY did not report a stall")
	}
	// The old upstream attachment must be gone before we let the PTY consume.
	deadline := time.After(time.Second)
	for active.Load() != 0 {
		select {
		case <-deadline:
			t.Fatal("stalled attachment remains open")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if attaches.Load() != 1 {
		t.Fatal("reconnected while output remained blocked")
	}
	recovered := make(chan struct{})
	drainDone := make(chan struct{})
	go func() {
		defer close(drainDone)
		var text []byte
		buf := make([]byte, 8192)
		for {
			n, err := master.Read(buf)
			text = append(text, buf[:n]...)
			if bytes.Contains(text, []byte("RECOVERED_SCREEN")) {
				close(recovered)
				return
			}
			if err != nil {
				return
			}
			if len(text) > 1<<20 {
				text = text[len(text)-8192:]
			}
		}
	}()
	select {
	case <-recovered:
	case <-ctx.Done():
		t.Fatal("screen did not replay after consumer resumed")
	}
	if attaches.Load() != 2 {
		t.Fatalf("unexpected retry count: %d", attaches.Load())
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("recovery did not cancel")
	}
	master.Close()
	<-drainDone
}

func TestLocalTerminalUsesSeparateNonblockingDescriptors(t *testing.T) {
	if os.Getenv("DISCOBOX_TEST_LOCAL_TTY") == "1" {
		before, err := unix.FcntlInt(os.Stdin.Fd(), unix.F_GETFL, 0)
		if err != nil {
			t.Fatal(err)
		}
		tty, err := openLocalTerminal()
		if err != nil {
			t.Fatal(err)
		}
		defer tty.close()
		after, err := unix.FcntlInt(os.Stdin.Fd(), unix.F_GETFL, 0)
		if err != nil || before != after {
			t.Fatal("opening tty changed inherited stdin flags")
		}
		if err := tty.write(t.Context(), []byte("OWNED_TTY_OK"), func(int) {}); err != nil {
			t.Fatal(err)
		}
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestLocalTerminalUsesSeparateNonblockingDescriptors$")
	cmd.Env = append(os.Environ(), "DISCOBOX_TEST_LOCAL_TTY=1")
	tty, err := pty.Start(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer tty.Close()
	timer := time.AfterFunc(3*time.Second, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	out, _ := io.ReadAll(tty)
	if err := cmd.Wait(); err != nil || !bytes.Contains(out, []byte("OWNED_TTY_OK")) {
		t.Fatalf("owned tty failed: %v %s", err, out)
	}
}

func TestLocalTerminalIdleReadDoesNotDisconnect(t *testing.T) {
	if os.Getenv("DISCOBOX_TEST_IDLE_TTY") == "1" {
		old, err := term.MakeRaw(int(os.Stdin.Fd()))
		if err != nil {
			t.Fatal(err)
		}
		defer term.Restore(int(os.Stdin.Fd()), old)
		tty, err := openLocalTerminal()
		if err != nil {
			t.Fatal(err)
		}
		defer tty.close()
		ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
		defer cancel()
		_, err = tty.read(ctx, make([]byte, 32))
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("idle input ended: %v", err)
		}
		// A timeout is only a wait boundary, not a closed descriptor. Input
		// arriving afterward must still be delivered byte-for-byte.
		if err := tty.write(t.Context(), []byte("PTY_INPUT_READY\n"), func(int) {}); err != nil {
			t.Fatal(err)
		}
		readCtx, stopRead := context.WithTimeout(t.Context(), time.Second)
		defer stopRead()
		var got []byte
		for len(got) < 3 {
			buf := make([]byte, 3-len(got))
			n, err := tty.read(readCtx, buf)
			if err != nil {
				t.Fatalf("input after idle: %v", err)
			}
			got = append(got, buf[:n]...)
		}
		if string(got) != "abc" {
			t.Fatalf("input changed: %q", got)
		}
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestLocalTerminalIdleReadDoesNotDisconnect$")
	cmd.Env = append(os.Environ(), "DISCOBOX_TEST_IDLE_TTY=1")
	tty, err := pty.Start(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer tty.Close()
	timer := time.AfterFunc(3*time.Second, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	reader := bufio.NewReader(tty)
	line, err := reader.ReadString('\n')
	if err != nil || line != "PTY_INPUT_READY\n" {
		out, _ := io.ReadAll(reader)
		_ = cmd.Wait()
		t.Fatalf("idle tty did not reach input: %v %s%s", err, line, out)
	}
	if _, err := tty.Write([]byte("abc")); err != nil {
		t.Fatal(err)
	}
	out, _ := io.ReadAll(reader)
	if err := cmd.Wait(); err != nil {
		t.Fatalf("idle tty failed: %v %s", err, out)
	}
}
