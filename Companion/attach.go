package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/pkg/execstream"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/resume"
	"golang.org/x/term"
)

type attachFrames struct {
	net.Conn
	mu     sync.Mutex
	cancel context.CancelFunc
}

func (c *attachFrames) Close() error {
	if c.cancel != nil {
		c.cancel()
	}
	return c.Conn.Close()
}

func (c *attachFrames) ReadFrame() (frame.Frame, error) { return frame.Read(c.Conn) }
func (c *attachFrames) WriteFrame(t byte, p []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return frame.Write(c.Conn, t, p)
}

func openAttach(ctx context.Context, endpoint string, req request) (*resume.Conn, error) {
	for _, id := range []string{req.ProjectID, req.SandboxID, req.ExecID} {
		if err := validID(id); err != nil {
			return nil, err
		}
	}
	if req.ExecID == "primary" {
		return nil, errors.New("a concrete terminal ID is required")
	}
	b, err := newBridge(endpoint, false)
	if err != nil {
		return nil, err
	}
	// Each physical attach is preceded by observational checks. Never call any
	// lifecycle route, and never retry an ended/cached terminal.
	dial := func(ctx context.Context) (execstream.Conn, error) {
		checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		if err := b.requireRunning(checkCtx, req); err != nil {
			return nil, err
		}
		address := b.base + "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/execs/" + req.ExecID + "/attach?replay=true"
		ws, _, err := websocket.Dial(checkCtx, address, &websocket.DialOptions{HTTPClient: b.client})
		if err != nil {
			return nil, err
		}
		ws.SetReadLimit(20 << 20)
		connectionCtx, cancelConnection := context.WithCancel(ctx)
		conn := &attachFrames{Conn: websocket.NetConn(connectionCtx, ws, websocket.MessageBinary), cancel: cancelConnection}
		go func() {
			ticker := time.NewTicker(15 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-connectionCtx.Done():
					return
				case <-ticker.C:
					pingCtx, cancelPing := context.WithTimeout(connectionCtx, 5*time.Second)
					err := ws.Ping(pingCtx)
					cancelPing()
					if err != nil {
						_ = conn.Close()
						return
					}
				}
			}
		}()
		return conn, nil
	}
	initial, err := dial(ctx)
	if err != nil {
		return nil, err
	}
	c, err := resume.New(ctx, initial, resume.Options{
		Dial: dial,
		Done: func(ctx context.Context) (bool, error) {
			err := b.requireRunning(ctx, req)
			return err != nil, err // Fail closed: user can explicitly reconnect after recovery.
		},
	})
	if err != nil {
		_ = initial.Close()
	}
	return c, err
}

// pumpAttach never sends CloseInput or Signal: closing the local surface only
// detaches this client. Ctrl-C typed in the raw PTY is ordinary remote input.
func pumpAttach(ctx context.Context, c execstream.Conn, input io.Reader, output io.Writer, sizes <-chan frame.ResizePayload) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer c.Close()
	done := make(chan error, 3)
	go func() { <-ctx.Done(); _ = c.Close() }()
	go func() {
		for {
			f, err := c.ReadFrame()
			if err != nil {
				done <- err
				return
			}
			switch f.Type {
			case frame.Stdout, frame.Stderr:
				if _, err = output.Write(f.Payload); err != nil {
					done <- err
					return
				}
			case frame.Error:
				done <- fmt.Errorf("terminal: %s", f.Payload)
				return
			case frame.Exit:
				done <- nil
				return
			}
		}
	}()
	// runAttach queues the current PTY size before entering this pump. Apply it
	// before Ready releases the host's screen replay, matching resume ordering.
	select {
	case size, ok := <-sizes:
		if ok && size.Cols > 0 && size.Rows > 0 {
			p, _ := json.Marshal(size)
			if err := c.WriteFrame(frame.Resize, p); err != nil {
				return err
			}
		}
	default:
	}
	if err := c.WriteFrame(frame.Ready, nil); err != nil {
		return err
	}
	go func() {
		buf := make([]byte, 32<<10)
		for {
			n, err := input.Read(buf)
			if n > 0 {
				if e := c.WriteFrame(frame.Input, buf[:n]); e != nil {
					done <- e
					return
				}
			}
			if err != nil {
				done <- err
				return
			}
		}
	}()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case size, ok := <-sizes:
				if !ok {
					return
				}
				if size.Cols == 0 || size.Rows == 0 {
					continue
				}
				p, _ := json.Marshal(size)
				if err := c.WriteFrame(frame.Resize, p); err != nil {
					done <- err
					return
				}
			}
		}
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-done:
		return err
	}
}

func runAttach(endpoint string, req request) error {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGTERM, os.Interrupt)
	defer cancel()
	fd := int(os.Stdin.Fd())
	old, err := term.MakeRaw(fd)
	if err != nil {
		return fmt.Errorf("terminal PTY required: %w", err)
	}
	defer term.Restore(fd, old)
	writeTerminalAppearance(os.Stdout)
	c, err := openAttach(ctx, endpoint, req)
	if err != nil {
		return err
	}
	resize := make(chan os.Signal, 1)
	signal.Notify(resize, syscall.SIGWINCH)
	defer signal.Stop(resize)
	sizes := make(chan frame.ResizePayload, 1)
	// Match the CLI's changed-size polling. SIGWINCH can be coalesced or
	// delivered before the embedded child's signal handler is ready.
	sendSize := changedTerminalSize(func() (int, int, error) { return term.GetSize(fd) }, sizes)
	sendSize()
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-resize:
				sendSize()
			case <-ticker.C:
				sendSize()
			}
		}
	}()
	return pumpAttach(ctx, c, os.Stdin, os.Stdout, sizes)
}

// One watcher owns the previous size and the latest-only queue. Polling reads
// the local PTY only; unchanged dimensions produce no network frames.
func changedTerminalSize(read func() (int, int, error), sizes chan frame.ResizePayload) func() {
	var previous frame.ResizePayload
	return func() {
		cols, rows, err := read()
		if err != nil || cols <= 0 || rows <= 0 || cols > 65535 || rows > 65535 {
			return
		}
		next := frame.ResizePayload{Cols: uint16(cols), Rows: uint16(rows)}
		if next != previous {
			enqueueLatestSize(sizes, next)
			previous = next
		}
	}
}

// One producer owns this single-slot queue. A slow socket must receive the
// latest geometry, not an intermediate drag position with the final one lost.
func enqueueLatestSize(sizes chan frame.ResizePayload, size frame.ResizePayload) {
	select {
	case sizes <- size:
		return
	default:
	}
	select {
	case <-sizes:
	default:
	}
	sizes <- size
}

// A synthetic PTY child for offline UI inspection. It never reads an endpoint.
func terminalDemo() error {
	fd := int(os.Stdin.Fd())
	old, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	defer term.Restore(fd, old)
	writeTerminalAppearance(os.Stdout)
	fmt.Print("\x1b[2J\x1b[H\x1b[38;5;81mDiscobox · Ghostty\x1b[0m\r\n\r\nLocal PTY demo — no backend connection.\r\nUnicode: café 日本語 🪩\r\nType to test input. Ctrl-C exits this demo.\r\n\r\n> ")
	b := make([]byte, 4096)
	for {
		n, err := os.Stdin.Read(b)
		if err != nil {
			return err
		}
		for _, c := range b[:n] {
			switch c {
			case 1:
				fmt.Print("\x1b[?1049h\x1b[2J\x1b[HAlternate screen fixture")
			case 2:
				fmt.Print("\x1b[?1049l")
			case 3:
				return nil
			case 10:
				fmt.Print("<LF>")
			case 27:
				fmt.Print("<ESC>")
			case 13:
				fmt.Print("<RETURN>\r\n> ")
			case 127:
				fmt.Print("\b \b")
			default:
				os.Stdout.Write([]byte{c})
			}
		}
	}
}
