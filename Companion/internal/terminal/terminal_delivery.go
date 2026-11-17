package terminal

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/pkg/execstream"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
)

var errTerminalStalled = errors.New("terminal output stalled; attachment closed to release backpressure")

const terminalQueueBytes = 32 << 20 // includes the writer's in-flight payload
const terminalQueueFrames = 256
const terminalWriteStall = 5 * time.Second

type terminalDelivery struct {
	read         func(context.Context, []byte) (int, error)
	write        func(context.Context, []byte, func(int)) error
	maxBytes     int64
	maxFrames    int
	waitForInput bool
}

type terminalProgress struct {
	received  atomic.Int64
	delivered atomic.Int64
	queued    atomic.Int64
	readAt    atomic.Int64
	writeAt   atomic.Int64
	start     time.Time
}

func (p *terminalProgress) snapshot(event, reason string) diagnostics.Event {
	now := time.Since(p.start).Milliseconds()
	return diagnostics.Event{Event: event, Reason: reason, Received: p.received.Load(), Delivered: p.delivered.Load(), Queue: p.queued.Load(), ReadAgeMS: now - p.readAt.Load(), WriteAgeMS: now - p.writeAt.Load()}
}

type deliveryFrame struct {
	frame frame.Frame
	err   error
}

// Only the reader touches the remote ReadFrame. The writer preserves frame
// order, including exit/error after preceding output. Capacity is charged
// until delivery finishes, not when a frame leaves the channel. The protocol
// also bounds a single incoming frame (20 MiB), in addition to this queue.
func pumpTerminal(ctx context.Context, c execstream.Conn, delivery terminalDelivery, sizes <-chan frame.ResizePayload) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer c.Close()
	if delivery.maxBytes <= 0 {
		delivery.maxBytes = terminalQueueBytes
	}
	if delivery.maxFrames <= 0 {
		delivery.maxFrames = terminalQueueFrames
	}
	queue := make(chan deliveryFrame, delivery.maxFrames)
	done := make(chan error, 4)
	progress := &terminalProgress{start: time.Now()}
	writerDone := make(chan struct{})
	inputDone := make(chan struct{})
	resizeDone := make(chan struct{})
	readerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		for {
			select {
			case <-ctx.Done():
				return
			case item := <-queue:
				f := item.frame
				if item.err != nil {
					done <- item.err
					return
				}
				switch f.Type {
				case frame.Stdout, frame.Stderr:
					err := delivery.write(ctx, f.Payload, func(n int) {
						progress.delivered.Add(int64(n))
						progress.writeAt.Store(time.Since(progress.start).Milliseconds())
					})
					progress.queued.Add(-int64(len(f.Payload)))
					if err != nil {
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
		}
	}()
	// The production writer is cancellation-aware. Wait for it to stop before
	// returning so no retired attachment can write into the next replay.
	defer func() { cancel(); _ = c.Close(); <-writerDone; <-readerDone }()
	go func() {
		defer close(readerDone)
		for {
			f, err := c.ReadFrame()
			progress.readAt.Store(time.Since(progress.start).Milliseconds())
			if err == nil && f.Type != frame.Stdout && f.Type != frame.Stderr && f.Type != frame.Exit && f.Type != frame.Error {
				continue
			}
			size := int64(len(f.Payload))
			progress.received.Add(size)
			if progress.queued.Add(size) > delivery.maxBytes {
				progress.queued.Add(-size)
				diagnostics.Emit(progress.snapshot("terminal_output_stalled", "byte_limit"))
				done <- errTerminalStalled
				return
			}
			select {
			case <-ctx.Done():
				return
			case queue <- deliveryFrame{frame: f, err: err}:
			default:
				progress.queued.Add(-size)
				diagnostics.Emit(progress.snapshot("terminal_output_stalled", "frame_limit"))
				done <- errTerminalStalled
				return
			}
			if err != nil || f.Type == frame.Exit || f.Type == frame.Error {
				return
			}
		}
	}()
	go func() { <-ctx.Done(); _ = c.Close() }()
	// Apply initial geometry before Ready releases replay.
	select {
	case size, ok := <-sizes:
		if ok && size.Cols > 0 && size.Rows > 0 {
			if err := writeResize(c, size); err != nil {
				return err
			}
		}
	default:
	}
	if err := c.WriteFrame(frame.Ready, nil); err != nil {
		return err
	}
	if delivery.waitForInput {
		defer func() { cancel(); _ = c.Close(); <-inputDone }()
	}
	go func() {
		defer close(inputDone)
		buf := make([]byte, 32<<10)
		for {
			n, err := delivery.read(ctx, buf)
			if ctx.Err() != nil {
				return
			}
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
	defer func() { cancel(); _ = c.Close(); <-resizeDone }()
	go func() {
		defer close(resizeDone)
		for {
			select {
			case <-ctx.Done():
				return
			case size, ok := <-sizes:
				if !ok {
					return
				}
				if size.Cols > 0 && size.Rows > 0 {
					if err := writeResize(c, size); err != nil {
						done <- err
						return
					}
				}
			}
		}
	}()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-done:
			reason := diagnostics.Reason(err)
			if errors.Is(err, errTerminalStalled) {
				reason = "output_stalled"
			}
			diagnostics.Emit(progress.snapshot("terminal_pump_stopped", reason))
			return err
		case <-ticker.C:
			diagnostics.Emit(progress.snapshot("terminal_progress", ""))
		}
	}
}

func writeResize(c execstream.Conn, size frame.ResizePayload) error {
	p := []byte(fmt.Sprintf(`{"cols":%d,"rows":%d}`, size.Cols, size.Rows))
	return c.WriteFrame(frame.Resize, p)
}
