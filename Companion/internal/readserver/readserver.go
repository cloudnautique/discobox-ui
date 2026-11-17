// Package readserver is the persistent read companion (--read-server): one
// process per app connection generation that serves concurrent read-only
// requests over one HTTP transport, so routine polling stops launching a
// helper per read. Writes, shells and transfers keep the one-shot,
// permission-scoped path in bridge.RunManaged.
//
// Framing, at wire.ReadServerVersion:
//
//	app → companion: one JSON line per frame, at most 128 KiB:
//	  {"version":1,"id":7,"type":"request","request":{…wire.Request…}}
//	  {"version":1,"id":7,"type":"cancel"}
//	companion → app: one JSON header line, then bodyLength raw body bytes:
//	  {"version":1,"id":7,"status":200,"bodyLength":123}\n<123 bytes>
//
// id is a transport correlation ID chosen by the app (nonzero, never reused
// by one process). It is unrelated to wire.Request.RequestID, which names an
// approval request. Every accepted request gets exactly one reply, in
// completion order; a cancelled one replies with its cancellation error,
// which the app has already stopped waiting for. The body travels as raw
// bytes after its header, so neither side base64-encodes it or parses it
// twice; JSON and non-JSON bodies are carried the same way.
//
// A frame that cannot be attributed to an id (oversized, unparsable, id 0,
// truncated by EOF) desynchronises the stream: the companion replies once
// with id 0 and exits. EOF on stdin is the parent-death signal, as for the
// Iroh proxy: in-flight reads are cancelled and the process exits.
package readserver

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

const (
	maxFrame = 128 << 10 // one request, as in one-shot mode
	// maxBody is the largest reply the app accepts, as for one-shot output.
	maxBody = 12 << 20
	// maxRunning reads use the transport at once; up to maxPending
	// (running + waiting) are admitted while waiting frames hold at most
	// maxQueuedBytes. Beyond that a read is refused at once rather than
	// buffered without bound.
	maxRunning     = 8
	maxPending     = 64
	maxQueuedBytes = 1 << 20
)

// Runner serves reads; *bridge.Reader in production.
type Runner interface {
	// Deadline refuses unknown and non-read operations before admission.
	Deadline(wire.Request) (time.Duration, error)
	Run(context.Context, wire.Request) (wire.Response, error)
}

var (
	ErrFrameTooLarge  = errors.New("request frame exceeds 128 KiB")
	ErrTruncatedFrame = errors.New("input ended inside a request frame")
	errVersion        = errors.New("Unsupported companion protocol version. Rebuild the app and companion together.")
	errBusy           = errors.New("too many companion reads are in flight; try again")
)

type frame struct {
	Version int             `json:"version"`
	ID      uint64          `json:"id"`
	Type    string          `json:"type"`
	Request json.RawMessage `json:"request,omitempty"`
}

type header struct {
	Version    int    `json:"version"`
	ID         uint64 `json:"id"`
	Status     int    `json:"status"`
	BodyLength int    `json:"bodyLength"`
	Error      string `json:"error,omitempty"`
	ErrorKind  string `json:"errorKind,omitempty"`
}

// Run serves reads for endpoint until in ends.
func Run(endpoint string, in io.Reader, out io.Writer) error {
	reader, err := bridge.NewReader(endpoint)
	if err != nil {
		writeHeader(out, header{Version: wire.ReadServerVersion, Error: err.Error(), ErrorKind: wire.ErrorKind(err)}, nil)
		return err
	}
	defer reader.Close()
	return Serve(in, out, reader)
}

type call struct {
	cancel context.CancelFunc
	size   int
	queued bool
}

type server struct {
	runner Runner
	ctx    context.Context
	stop   context.CancelFunc
	slots  chan struct{}
	wg     sync.WaitGroup

	mu          sync.Mutex
	calls       map[uint64]*call
	queuedBytes int

	writeMu  sync.Mutex
	out      io.Writer
	writeErr error
}

// Serve reads frames from in until EOF (nil) or a stream error, which it
// reports once with id 0 before returning it. Either way every in-flight
// read is cancelled and has replied (or failed to) before Serve returns.
func Serve(in io.Reader, out io.Writer, runner Runner) error {
	ctx, stop := context.WithCancel(context.Background())
	s := &server{runner: runner, ctx: ctx, stop: stop, slots: make(chan struct{}, maxRunning), calls: map[uint64]*call{}, out: out}
	input := bufio.NewReaderSize(in, 64<<10)
	for {
		line, err := readFrame(input)
		if err == nil {
			err = s.handle(line)
		}
		if err != nil {
			stop()
			s.wg.Wait()
			if err == io.EOF {
				return nil
			}
			s.write(header{Error: err.Error()}, nil)
			return err
		}
	}
}

func readFrame(input *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		chunk, err := input.ReadSlice('\n')
		if len(line)+len(chunk) > maxFrame+1 {
			return nil, ErrFrameTooLarge
		}
		line = append(line, chunk...)
		switch {
		case err == nil:
			return line[:len(line)-1], nil
		case errors.Is(err, bufio.ErrBufferFull):
		case err == io.EOF && len(line) == 0:
			return nil, io.EOF
		case err == io.EOF:
			return nil, ErrTruncatedFrame
		default:
			return nil, err
		}
	}
}

func strictDecode(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}

// handle returns an error only when the stream itself is unusable.
func (s *server) handle(line []byte) error {
	var f frame
	if err := strictDecode(line, &f); err != nil {
		return fmt.Errorf("invalid request frame: %w", err)
	}
	if f.ID == 0 {
		return errors.New("invalid request frame: missing id")
	}
	if f.Version != wire.ReadServerVersion {
		s.reply(f.ID, wire.Response{}, errVersion)
		return nil
	}
	switch f.Type {
	case "cancel":
		s.mu.Lock()
		c := s.calls[f.ID]
		s.mu.Unlock()
		if c != nil {
			c.cancel()
		}
	case "request":
		var req wire.Request
		if err := strictDecode(f.Request, &req); err != nil {
			s.reply(f.ID, wire.Response{}, fmt.Errorf("invalid request: %w", err))
			return nil
		}
		s.start(f.ID, req, len(line))
	default:
		s.reply(f.ID, wire.Response{}, fmt.Errorf("unsupported frame type %q", f.Type))
	}
	return nil
}

func (s *server) start(id uint64, req wire.Request, size int) {
	deadline, err := s.runner.Deadline(req)
	if err != nil {
		s.reply(id, wire.Response{}, err)
		return
	}
	s.mu.Lock()
	if _, duplicate := s.calls[id]; duplicate {
		s.mu.Unlock()
		s.reply(id, wire.Response{}, errors.New("duplicate request id"))
		return
	}
	if len(s.calls) >= maxPending || s.queuedBytes+size > maxQueuedBytes {
		s.mu.Unlock()
		s.write(header{ID: id, Error: errBusy.Error(), ErrorKind: wire.KindTransport}, nil)
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, deadline)
	c := &call{cancel: cancel, size: size, queued: true}
	s.calls[id] = c
	s.queuedBytes += size
	s.wg.Add(1)
	s.mu.Unlock()
	go s.serve(ctx, id, req, c)
}

func (s *server) serve(ctx context.Context, id uint64, req wire.Request, c *call) {
	defer s.wg.Done()
	defer c.cancel()
	var res wire.Response
	var err error
	select {
	case s.slots <- struct{}{}:
		s.dequeue(c)
		if err = ctx.Err(); err == nil {
			res, err = s.runner.Run(ctx, req)
		}
		<-s.slots
	case <-ctx.Done():
		s.dequeue(c)
		err = ctx.Err()
	}
	s.reply(id, res, err)
	s.mu.Lock()
	delete(s.calls, id)
	s.mu.Unlock()
}

func (s *server) dequeue(c *call) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.queued {
		c.queued = false
		s.queuedBytes -= c.size
	}
}

func (s *server) reply(id uint64, res wire.Response, err error) {
	h := header{ID: id, Status: res.Status, Error: res.Error, ErrorKind: res.ErrorKind}
	switch {
	case err != nil:
		h = header{ID: id, Error: err.Error(), ErrorKind: wire.ErrorKind(err)}
		res.Body = nil
	case len(res.Body) > maxBody:
		h = header{ID: id, Error: "response exceeds 12 MiB"}
		res.Body = nil
	}
	s.write(h, res.Body)
}

// write sends one reply atomically. After a write error (the app is gone)
// it cancels everything and drops later replies.
func (s *server) write(h header, body []byte) {
	h.Version = wire.ReadServerVersion
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if s.writeErr != nil {
		return
	}
	if s.writeErr = writeHeader(s.out, h, body); s.writeErr != nil {
		s.stop()
	}
}

func writeHeader(out io.Writer, h header, body []byte) error {
	h.BodyLength = len(body)
	line, err := json.Marshal(h)
	if err != nil {
		return err
	}
	if _, err := out.Write(append(line, '\n')); err != nil {
		return err
	}
	if len(body) > 0 {
		_, err = out.Write(body)
	}
	return err
}
