package terminal

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/fdwait"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"github.com/discobox-ai/discobox/pkg/execstream/resume"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

func runTerminalRecovery(ctx context.Context, endpoint string, req wire.Request, tty *localTerminal, sizes <-chan frame.ResizePayload, status func(string, string), statusPath string, autoReconnect bool) error {
	var wait func(context.Context, time.Duration) error
	if autoReconnect {
		wait = func(ctx context.Context, delay time.Duration) error {
			status("reconnecting", fmt.Sprintf("Next connection attempt in %s.", delay.Round(time.Second)))
			return waitForRecovery(ctx, delay)
		}
	}
	stalls := 0
	for {
		attemptCtx, cancel := context.WithCancel(ctx)
		c, err := openAttach(attemptCtx, endpoint, req, func(e resume.Event) { status(string(e.State), "") }, statusPath, wait)
		if err != nil {
			cancel()
			return err
		}
		// A fresh attachment needs current geometry even if the size poller has not
		// changed since the last attachment. Do not race that poller's queue producer.
		if cols, rows, e := term.GetSize(tty.input); e == nil && cols > 0 && rows > 0 && cols <= 65535 && rows <= 65535 {
			err = writeResize(c, frame.ResizePayload{Cols: uint16(cols), Rows: uint16(rows)})
		}
		if err != nil {
			cancel()
			c.Close()
			return err
		}
		status("connected", "")
		started := time.Now()
		err = pumpTerminal(attemptCtx, c, terminalDelivery{read: tty.read, write: tty.write, waitForInput: true}, sizes)
		cancel()
		c.Close()
		if !autoReconnect && err != nil {
			return fmt.Errorf("Automatic reconnect is paused. Reconnect to resume this terminal: %w", err)
		}
		if !errors.Is(err, errTerminalStalled) {
			return err
		}
		if time.Since(started) > time.Minute {
			stalls = 0
		}
		stalls++
		status("output-stalled", "Terminal output stalled. Waiting for local delivery before reconnecting…")
		diagnostics.Emit(diagnostics.Event{Event: "terminal_output_stalled", Reason: "delivery", Retry: stalls})
		if stalls >= 3 {
			return errTerminalStalled
		}
		// No network attachment or input reader while local delivery is stalled.
		// Allow up to 30s for Ghostty to drain; then leave readable output and an
		// explicit Reconnect action, rather than retrying forever in the background.
		if err := waitForTerminalConsumer(ctx, tty.output); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(stalls) * time.Second):
		}
		if err := flushTerminalInput(tty.input); err != nil {
			return err
		}
		status("reconnecting", "Local output resumed. Restoring the terminal screen…")
		// Cancel a partial escape sequence before the authoritative screen replay.
		// Already delivered PTY bytes precede this boundary; no old writer survives.
		if err := tty.write(ctx, []byte("\x18\x1b[0m"), func(int) {}); err != nil {
			return err
		}
		diagnostics.Emit(diagnostics.Event{Event: "terminal_delivery_recovered"})
	}
}

func waitForTerminalConsumer(ctx context.Context, fd int) error {
	waitCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := fdwait.Wait(waitCtx, fd, unix.POLLOUT); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errTerminalStalled
	}
	return nil
}
