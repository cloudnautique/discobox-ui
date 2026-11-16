package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/creack/pty"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

type deliveryConnection struct {
	frames chan frame.Frame
	closed chan struct{}
	once   sync.Once
	reads  atomic.Int64
}

func newDeliveryConnection() *deliveryConnection {
	return &deliveryConnection{frames: make(chan frame.Frame, 16), closed: make(chan struct{})}
}
func (c *deliveryConnection) ReadFrame() (frame.Frame, error) {
	select {
	case f := <-c.frames:
		c.reads.Add(1)
		return f, nil
	case <-c.closed:
		return frame.Frame{}, io.EOF
	}
}
func (c *deliveryConnection) WriteFrame(typ byte, p []byte) error {
	if typ != frame.Ready && typ != frame.Resize {
		return errors.New("unexpected input or mutation")
	}
	return nil
}
func (c *deliveryConnection) Close() error                         { c.once.Do(func() { close(c.closed) }); return nil }
func idleTerminalInput(ctx context.Context, _ []byte) (int, error) { <-ctx.Done(); return 0, ctx.Err() }

func TestTerminalReaderContinuesWhileDeliveryWaitsAndExitFollowsOutput(t *testing.T) {
	c := newDeliveryConnection()
	writing, release := make(chan struct{}), make(chan struct{})
	var output bytes.Buffer
	var once sync.Once
	result := make(chan error, 1)
	go func() {
		result <- pumpTerminal(t.Context(), c, terminalDelivery{read: idleTerminalInput, waitForInput: true,
			write: func(ctx context.Context, p []byte, progress func(int)) error {
				once.Do(func() { close(writing) })
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-release:
				}
				n, err := output.Write(p)
				progress(n)
				return err
			}}, nil)
	}()
	c.frames <- frame.Frame{Type: frame.Stdout, Payload: []byte("one")}
	<-writing
	c.frames <- frame.Frame{Type: frame.Stderr, Payload: []byte("two")}
	c.frames <- frame.Frame{Type: frame.Exit}
	deadline := time.After(time.Second)
	for c.reads.Load() < 3 {
		select {
		case <-deadline:
			t.Fatal("remote reader blocked behind local writer")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	select {
	case <-result:
		t.Fatal("exit overtook queued output")
	default:
	}
	close(release)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("delivery did not complete")
	}
	if output.String() != "onetwo" {
		t.Fatalf("output order: %q", output.String())
	}
}

func TestTerminalQueueLimitsIncludeBlockedInFlightOutput(t *testing.T) {
	for _, tc := range []struct {
		name      string
		maxBytes  int64
		maxFrames int
		count     int
		payload   string
	}{
		{"bytes", 8, 10, 2, "123456"}, {"frames", 1024, 2, 4, "x"}, {"single oversized frame", 8, 10, 1, "123456789"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newDeliveryConnection()
			var writing atomic.Bool
			result := make(chan error, 1)
			go func() {
				result <- pumpTerminal(t.Context(), c, terminalDelivery{read: idleTerminalInput, waitForInput: true,
					maxBytes: tc.maxBytes, maxFrames: tc.maxFrames,
					write: func(ctx context.Context, _ []byte, _ func(int)) error {
						writing.Store(true)
						defer writing.Store(false)
						<-ctx.Done()
						return ctx.Err()
					},
				}, nil)
			}()
			for range tc.count {
				c.frames <- frame.Frame{Type: frame.Stdout, Payload: []byte(tc.payload)}
			}
			select {
			case err := <-result:
				if !errors.Is(err, errTerminalStalled) {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("queue failed to bound blocked output")
			}
			if writing.Load() {
				t.Fatal("retired writer survived pump shutdown")
			}
			select {
			case <-c.closed:
			default:
				t.Fatal("remote attachment left open")
			}
		})
	}
}
func TestIdleTerminalIsNotAnOutputStall(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	err := pumpTerminal(ctx, newDeliveryConnection(), terminalDelivery{read: idleTerminalInput, waitForInput: true,
		write: func(context.Context, []byte, func(int)) error { t.Error("unexpected output"); return nil },
	}, nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("idle was treated as stall: %v", err)
	}
}

func TestPTYOutputStallAndCancellationAreBounded(t *testing.T) {
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
	var delivered int
	err = writeTerminalFD(t.Context(), fd, make([]byte, 4<<20), 100*time.Millisecond, func(n int) { delivered += n })
	if !errors.Is(err, errTerminalStalled) || delivered == 0 {
		t.Fatalf("did not exercise partial output followed by stall: %d %v", delivered, err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- writeTerminalFD(ctx, fd, make([]byte, 4<<20), time.Hour, func(int) {}) }()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("writer ignored cancellation")
	}
	// Clear queued keystrokes without discarding already delivered screen bytes.
	if err := flushTerminalInput(fd); err != nil {
		t.Fatal(err)
	}
}

func TestPTYPartialWritesPreserveBytesAndCanResumeAfterDrain(t *testing.T) {
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
	data := bytes.Repeat([]byte("exact bytes\x1b[32m\n"), 10000)
	result := make(chan []byte, 1)
	go func() { p := make([]byte, len(data)); _, _ = io.ReadFull(master, p); result <- p }()
	count := 0
	if err := writeTerminalFD(t.Context(), fd, data, time.Second, func(n int) { count += n }); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-result:
		if !bytes.Equal(got, data) || count != len(data) {
			t.Fatal("partial writes changed output")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("PTY did not drain")
	}
	if err := waitForTerminalConsumer(t.Context(), fd); err != nil {
		t.Fatal(err)
	}
}
