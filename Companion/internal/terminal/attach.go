// Package terminal runs the --attach mode: it streams one live, concrete
// terminal between the local PTY (Ghostty's /dev/tty) and the server's
// resumable exec WebSocket, reporting connection state through a private
// FIFO. It never starts a box or revives an ended terminal. --terminal-demo
// runs an offline PTY fixture instead.
package terminal

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/execstream"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/resume"
	"golang.org/x/term"
)

var attachGeneration atomic.Int64

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

func openAttach(ctx context.Context, endpoint string, req wire.Request, event func(resume.Event), statusPath string, recoveryWait func(context.Context, time.Duration) error) (*resume.Conn, error) {
	for _, id := range []string{req.ProjectID, req.SandboxID, req.ExecID} {
		if err := bridge.ValidID(id); err != nil {
			return nil, err
		}
	}
	if req.ExecID == "primary" {
		return nil, errors.New("a concrete terminal ID is required")
	}
	b, err := bridge.New(endpoint)
	if err != nil {
		return nil, err
	}
	// Each physical attach is preceded by observational checks. Never call any
	// lifecycle route, and never retry an ended/cached terminal.
	dial := func(ctx context.Context) (execstream.Conn, error) {
		attempt := attachGeneration.Add(1)
		diagnostics.Emit(diagnostics.Event{Event: "attach_dial", Generation: attempt})
		checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		if err := b.RequireRunning(checkCtx, req); err != nil {
			return nil, err
		}
		address := b.BaseURL() + "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/execs/" + req.ExecID + "/attach?replay=true"
		headers := make(http.Header)
		if diagnostics.Enabled() {
			headers.Set("X-Discobox-UI-Attachment", diagnostics.Session())
		}
		ws, response, err := websocket.Dial(checkCtx, address, &websocket.DialOptions{HTTPClient: b.HTTPClient(), HTTPHeader: headers})
		if err != nil {
			status := 0
			if response != nil {
				status = response.StatusCode
			}
			diagnostics.Emit(diagnostics.Event{Event: "attach_dial_failed", Generation: attempt, Reason: diagnostics.Reason(err), HTTPStatus: status})
			return nil, err
		}
		diagnostics.Emit(diagnostics.Event{Event: "attach_connected", Generation: attempt})
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
					started := time.Now()
					err := ws.Ping(pingCtx)
					diagnostics.Emit(diagnostics.Event{Event: "attach_ping", Generation: attempt, Reason: diagnostics.Reason(err), DurationMS: time.Since(started).Milliseconds()})
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
	ctx = diagnostics.ObserveAttachActions(ctx)
	// resume serializes recovery callbacks. Done precedes Dial on each attempt,
	// including retries after an unsuccessful replay handshake.
	var observationErr error
	attempt := 0
	quickFirst := false
	established := time.Now()
	opts := resume.Options{
		Event: func(e resume.Event) {
			switch e.State {
			case resume.ConnectionReconnecting:
				if time.Since(established) >= 30*time.Second {
					attempt = 0
				}
			case resume.ConnectionReconnected:
				established = time.Now()
			}
			diagnostics.Emit(diagnostics.Event{Event: "attach_" + string(e.State), Reason: diagnostics.Reason(e.Err)})
			if event != nil {
				event(e)
			}
		},
	}
	if recoveryWait != nil {
		opts.Done = func(ctx context.Context) (bool, error) {
			if attempt == 0 {
				quickFirst = attachmentVisible(statusPath)
			}
			attempt = min(attempt+1, 6)
			delay := recoveryDelay(attempt, quickFirst)
			diagnostics.Emit(diagnostics.Event{Event: "attach_wait", Retry: attempt, DurationMS: delay.Milliseconds()})
			if err := recoveryWait(ctx, delay); err != nil {
				return true, err
			}
			done, err := attachDone(ctx, b, req)
			observationErr = err
			return done, err
		}
		opts.Dial = func(ctx context.Context) (execstream.Conn, error) {
			if observationErr != nil {
				return nil, observationErr
			}
			return dial(ctx)
		}
	}
	c, err := resume.New(ctx, initial, opts)
	if err != nil {
		_ = initial.Close()
	}
	return c, err
}

// A failed observation is unknown, not proof that the remote process ended.
// Keep upstream's resumable connection alive across pool/network outages, but
// never start a box or revive an ended concrete exec while reconnecting.
func attachDone(ctx context.Context, b *bridge.Bridge, req wire.Request) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	terminal, readErr := b.Call(ctx, http.MethodGet, "/api/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID+"/execs/"+req.ExecID, nil)
	if terminal.Status == http.StatusUnauthorized || terminal.Status == http.StatusForbidden {
		return true, errors.New("terminal access was refused; check this computer’s authorization before reconnecting")
	}
	var exec struct {
		Status     string  `json:"status"`
		ObservedAt *string `json:"observedAt"`
	}
	if readErr == nil && terminal.Status == http.StatusOK && json.Unmarshal(terminal.Body, &exec) == nil && exec.ObservedAt == nil {
		switch exec.Status {
		case "exited", "failed", "lost":
			return true, fmt.Errorf("terminal is %s; detaching", exec.Status)
		case "running":
			return false, nil
		}
	}
	box, err := b.Call(ctx, http.MethodGet, "/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID, nil)
	if box.Status == http.StatusUnauthorized || box.Status == http.StatusForbidden {
		return true, errors.New("box access was refused; check this computer’s authorization before reconnecting")
	}
	var state struct {
		Runtime struct {
			State        string `json:"state"`
			RuntimeState string `json:"runtimeState"`
			DisplayState string `json:"displayState"`
		} `json:"runtime"`
	}
	if err == nil && box.Status == http.StatusOK && json.Unmarshal(box.Body, &state) == nil && state.Runtime.DisplayState != "repairing" {
		switch state.Runtime.RuntimeState {
		case "stopped", "stopping", "suspended":
			return true, fmt.Errorf("box is %s; detaching", state.Runtime.RuntimeState)
		}
		switch state.Runtime.State {
		case "failed", "archived", "deleted":
			return true, fmt.Errorf("box is %s; detaching", state.Runtime.State)
		}
	}
	if readErr == nil && terminal.Status != http.StatusOK {
		readErr = fmt.Errorf("terminal observation returned HTTP %d", terminal.Status)
	}
	return false, readErr
}

// The UI owns this marker alongside its private status FIFO. Missing status
// (including standalone helpers) keeps the conservative hidden-session policy.
func attachmentVisible(statusPath string) bool {
	if statusPath == "" {
		return false
	}
	info, err := os.Lstat(statusPath + ".visible")
	return err == nil && info.Mode().IsRegular()
}

// Give an on-screen terminal one fast retry per stable connection. Later
// attempts use the same jittered backoff as a retained off-screen session.
func recoveryDelay(attempt int, quickFirst bool) time.Duration {
	if quickFirst {
		if attempt == 1 {
			return time.Second + time.Duration(rand.Int64N(int64(250*time.Millisecond)+1))
		}
		attempt--
	}
	floor := min(30*time.Second<<(max(1, min(attempt, 5))-1), 270*time.Second)
	return floor + time.Duration(rand.Int64N(int64(floor/9)+1))
}

func waitForRecovery(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Attach streams the terminal req names until it ends or the parent leaves.
// statusPath, when set, is the FIFO that receives connection state.
func Attach(endpoint string, req wire.Request, statusPath string, autoReconnect bool) (resultErr error) {
	status, closeStatus := attachStatusWriter(statusPath)
	defer closeStatus()
	status("connecting", "")
	defer func() {
		if errors.Is(resultErr, errTerminalStalled) {
			status("output-stalled", "Terminal output is still stalled. Previous output is read-only; reconnect when ready.")
		} else if resultErr != nil {
			status("disconnected", resultErr.Error())
		} else {
			status("ended", "")
		}
	}()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGTERM, os.Interrupt)
	defer cancel()
	fd := int(os.Stdin.Fd())
	old, err := term.MakeRaw(fd)
	if err != nil {
		return fmt.Errorf("terminal PTY required: %w", err)
	}
	defer term.Restore(fd, old)
	tty, err := openLocalTerminal()
	if err != nil {
		return err
	}
	defer tty.close()
	// Appearance setup is small but uses the same bounded writer as remote data.
	var appearance bytes.Buffer
	writeTerminalAppearance(&appearance)
	if err := tty.write(ctx, appearance.Bytes(), func(int) {}); err != nil {
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
	return runTerminalRecovery(ctx, endpoint, req, tty, sizes, status, statusPath, autoReconnect)
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

// Demo is a synthetic PTY child for offline UI inspection. It never reads an endpoint.
func Demo() error {
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
			case 4:
				fmt.Print("\x1b[?1hApplication cursor keys enabled\r\n")
			case 5:
				fmt.Print("\x1b[?1l\x1b[>1uExtended keyboard protocol enabled\r\n")
			case 6:
				fmt.Print("\x1b[<uExtended keyboard protocol disabled\r\n")
			case 7:
				cols, rows, err := term.GetSize(fd)
				if err == nil {
					fmt.Printf("<PTY:%dx%d>", cols, rows)
				}
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
