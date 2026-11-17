package diagnostics

import (
	"context"
	"strings"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/fdwait"
	"golang.org/x/sys/unix"
)

// The native Iroh library writes to fd 2 rather than the Go log writer. Drain
// it separately from the startup protocol, reducing lines to safe categories.
// Both pipe ends are nonblocking: a full diagnostics pipe cannot hold a native
// transport thread. Raw native text is never persisted.
func CaptureIrohStderr() func() {
	if transportDiagnostics == nil {
		return func() {}
	}
	fds := make([]int, 2)
	if err := unix.Pipe(fds); err != nil {
		return func() {}
	}
	for _, fd := range fds {
		unix.CloseOnExec(fd)
	}
	if unix.SetNonblock(fds[0], true) != nil || unix.SetNonblock(fds[1], true) != nil {
		unix.Close(fds[0])
		unix.Close(fds[1])
		return func() {}
	}
	original, err := unix.Dup(2)
	if err != nil {
		unix.Close(fds[0])
		unix.Close(fds[1])
		return func() {}
	}
	unix.CloseOnExec(original)
	if err := unix.Dup2(fds[1], 2); err != nil {
		unix.Close(original)
		unix.Close(fds[0])
		unix.Close(fds[1])
		return func() {}
	}
	unix.Close(fds[1])
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer unix.Close(fds[0])
		buf := make([]byte, 4096)
		for {
			if fdwait.Wait(ctx, fds[0], unix.POLLIN) != nil {
				return
			}
			n, err := unix.Read(fds[0], buf)
			if err == unix.EAGAIN || err == unix.EINTR {
				continue
			}
			if err != nil || n <= 0 {
				return
			}
			reason := nativeIrohCategory(buf[:n])
			Emit(Event{Event: "iroh_native_diagnostic", Reason: reason})
		}
	}()
	return func() {
		// Restore fd 2 before closing the reader so late native logs cannot SIGPIPE.
		_ = unix.Dup2(original, 2)
		_ = unix.Close(original)
		cancel()
		select {
		case <-done:
		case <-time.After(250 * time.Millisecond):
		}
	}
}
func nativeIrohCategory(p []byte) string {
	s := strings.ToLower(string(p))
	if strings.Contains(s, "error") {
		return "error"
	}
	if strings.Contains(s, "warn") {
		return "warning"
	}
	return "event"
}
