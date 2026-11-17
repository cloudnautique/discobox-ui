// Package fdwait waits, in bounded steps, for a nonblocking descriptor to
// become readable or writable. Each step is at most 50ms, so cancellation is
// noticed without closing an FD from another goroutine. The terminal uses it
// for /dev/tty and diagnostics for its private stderr pipe.
package fdwait

import (
	"context"
	"errors"

	"golang.org/x/sys/unix"
)

// Wait returns once fd is ready for events (unix.POLLIN or unix.POLLOUT), or
// with ctx's error.
func Wait(ctx context.Context, fd int, events int16) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		ok, err := ready(fd, events)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
	}
}
