package main

import (
	"context"
	"errors"
	"io"
	"time"

	"golang.org/x/sys/unix"
)

// Separate open descriptions: O_NONBLOCK must not change Ghostty's or stdin's
// inherited flags. Readiness waits are bounded so cancellation never closes an FD
// from another goroutine or race with descriptor reuse.
type localTerminal struct{ input, output int }

func openLocalTerminal() (*localTerminal, error) {
	input, err := unix.Open("/dev/tty", unix.O_RDONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	output, err := unix.Open("/dev/tty", unix.O_WRONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		unix.Close(input)
		return nil, err
	}
	return &localTerminal{input: input, output: output}, nil
}
func (t *localTerminal) close() { unix.Close(t.input); unix.Close(t.output) }
func waitTerminalFD(ctx context.Context, fd int, events int16) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		ready, err := terminalFDReady(fd, events)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if ready {
			return nil
		}
	}
}
func (t *localTerminal) read(ctx context.Context, p []byte) (int, error) {
	for {
		if err := waitTerminalFD(ctx, t.input, unix.POLLIN); err != nil {
			return 0, err
		}
		n, err := unix.Read(t.input, p)
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) {
			continue
		}
		if err == nil && n == 0 {
			err = io.EOF
		}
		return n, err
	}
}
func writeTerminalFD(ctx context.Context, fd int, data []byte, stall time.Duration, progress func(int)) error {
	lastProgress := time.Now()
	for len(data) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		if time.Since(lastProgress) >= stall {
			return errTerminalStalled
		}
		// Limit each syscall, but charge the full payload in the delivery queue.
		chunk := data
		if len(chunk) > 16<<10 {
			chunk = chunk[:16<<10]
		}
		n, err := unix.Write(fd, chunk)
		if n > 0 {
			progress(n)
			data = data[n:]
			lastProgress = time.Now()
		}
		if err != nil && !errors.Is(err, unix.EAGAIN) && !errors.Is(err, unix.EINTR) {
			return err
		}
		if n <= 0 {
			waitCtx, cancel := context.WithDeadline(ctx, lastProgress.Add(stall))
			err := waitTerminalFD(waitCtx, fd, unix.POLLOUT)
			cancel()
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if errors.Is(err, context.DeadlineExceeded) {
				return errTerminalStalled
			}
			if err != nil {
				return err
			}
		}
	}
	return nil
}
func (t *localTerminal) write(ctx context.Context, p []byte, progress func(int)) error {
	return writeTerminalFD(ctx, t.output, p, terminalWriteStall, progress)
}
