package readserver

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// gatedRunner holds each read until the test releases its sandbox ID (or
// the read's context ends), so replies can be ordered without timing.
type gatedRunner struct {
	mu      sync.Mutex
	gates   map[string]chan wire.Response
	started chan string
}

func newGatedRunner() *gatedRunner {
	return &gatedRunner{gates: map[string]chan wire.Response{}, started: make(chan string, 128)}
}

func (r *gatedRunner) gate(name string) chan wire.Response {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.gates[name] == nil {
		r.gates[name] = make(chan wire.Response, 1)
	}
	return r.gates[name]
}

func (r *gatedRunner) Deadline(req wire.Request) (time.Duration, error) {
	if req.Operation != "sandboxes" {
		return 0, errors.New("not a read")
	}
	return time.Minute, nil
}

func (r *gatedRunner) Run(ctx context.Context, req wire.Request) (wire.Response, error) {
	gate := r.gate(req.SandboxID)
	r.started <- req.SandboxID
	select {
	case res := <-gate:
		return res, nil
	case <-ctx.Done():
		return wire.Response{}, ctx.Err()
	}
}

type reply struct {
	header
	body []byte
}

type harness struct {
	t       *testing.T
	in      *io.PipeWriter
	replies chan reply
	done    chan error
}

func serve(t *testing.T, runner Runner) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &harness{t: t, in: inW, replies: make(chan reply, 128), done: make(chan error, 1)}
	go func() {
		err := Serve(inR, outW, runner)
		_ = outW.Close()
		h.done <- err
	}()
	go func() {
		defer close(h.replies)
		output := bufio.NewReader(outR)
		for {
			line, err := output.ReadBytes('\n')
			if err != nil {
				return
			}
			var r reply
			if err := json.Unmarshal(line, &r.header); err != nil {
				t.Errorf("invalid reply header %q: %v", line, err)
				return
			}
			r.body = make([]byte, r.BodyLength)
			if _, err := io.ReadFull(output, r.body); err != nil {
				t.Errorf("short body: %v", err)
				return
			}
			h.replies <- r
		}
	}()
	t.Cleanup(func() { _ = inW.Close(); _ = outR.Close() })
	return h
}

func (h *harness) send(format string, args ...any) {
	h.t.Helper()
	if _, err := fmt.Fprintf(h.in, format, args...); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) request(id uint64, box string) {
	h.send(`{"version":%d,"id":%d,"type":"request","request":{"operation":"sandboxes","projectID":"p","sandboxID":%q,"execID":""}}`+"\n", wire.ReadServerVersion, id, box)
}

func (h *harness) next() reply {
	h.t.Helper()
	select {
	case r, ok := <-h.replies:
		if !ok {
			h.t.Fatal("companion output ended")
		}
		if r.Version != wire.ReadServerVersion {
			h.t.Fatalf("reply version %d", r.Version)
		}
		return r
	case <-time.After(10 * time.Second):
		h.t.Fatal("no reply")
	}
	return reply{}
}

func (h *harness) finished() error {
	h.t.Helper()
	select {
	case err := <-h.done:
		return err
	case <-time.After(10 * time.Second):
		h.t.Fatal("server did not exit")
	}
	return nil
}

func waitStarted(t *testing.T, r *gatedRunner, want ...string) {
	t.Helper()
	seen := map[string]bool{}
	for len(seen) < len(want) {
		select {
		case box := <-r.started:
			seen[box] = true
		case <-time.After(10 * time.Second):
			t.Fatalf("reads did not start: %v", seen)
		}
	}
}

func TestRepliesCarryRawBodiesAndMayCompleteOutOfOrder(t *testing.T) {
	runner := newGatedRunner()
	h := serve(t, runner)
	h.request(1, "slow")
	h.request(2, "fast")
	waitStarted(t, runner, "slow", "fast")
	runner.gate("fast") <- wire.Response{Status: 200, Body: []byte("{\"fast\":\n true}")}
	if r := h.next(); r.ID != 2 || r.Status != 200 || string(r.body) != "{\"fast\":\n true}" {
		t.Fatalf("first reply %+v %q", r.header, r.body)
	}
	runner.gate("slow") <- wire.Response{Status: 404, Body: []byte("not json \x00")}
	if r := h.next(); r.ID != 1 || r.Status != 404 || string(r.body) != "not json \x00" {
		t.Fatalf("second reply %+v %q", r.header, r.body)
	}
	_ = h.in.Close()
	if err := h.finished(); err != nil {
		t.Fatal(err)
	}
}

func TestCancellingOneReadLeavesOthersRunning(t *testing.T) {
	runner := newGatedRunner()
	h := serve(t, runner)
	h.request(1, "cancelled")
	h.request(2, "kept")
	waitStarted(t, runner, "cancelled", "kept")
	h.send(`{"version":%d,"id":1,"type":"cancel"}`+"\n", wire.ReadServerVersion)
	if r := h.next(); r.ID != 1 || !strings.Contains(r.Error, "canceled") {
		t.Fatalf("cancelled reply %+v", r.header)
	}
	runner.gate("kept") <- wire.Response{Status: 200, Body: []byte(`{}`)}
	if r := h.next(); r.ID != 2 || r.Status != 200 || r.Error != "" {
		t.Fatalf("kept reply %+v", r.header)
	}
	// Cancelling an unknown or finished id is harmless.
	h.send(`{"version":%d,"id":9,"type":"cancel"}`+"\n", wire.ReadServerVersion)
	h.request(3, "after")
	waitStarted(t, runner, "after")
	runner.gate("after") <- wire.Response{Status: 200}
	if r := h.next(); r.ID != 3 {
		t.Fatalf("after reply %+v", r.header)
	}
}

func TestPerRequestRefusalsKeepTheStream(t *testing.T) {
	reader, err := bridge.NewReader("http://127.0.0.1:1")
	if err != nil {
		t.Fatal(err)
	}
	h := serve(t, reader)
	v := wire.ReadServerVersion
	for _, tc := range []struct{ frame, want string }{
		{fmt.Sprintf(`{"version":%d,"id":1,"type":"request","request":{"operation":"answer","projectID":"p","sandboxID":"","execID":""}}`, v), "only read operations"},
		{fmt.Sprintf(`{"version":%d,"id":2,"type":"request","request":{"operation":"newShell","projectID":"p","sandboxID":"s","execID":""}}`, v), "only read operations"},
		{fmt.Sprintf(`{"version":%d,"id":3,"type":"request","request":{"operation":"ruleProposals","projectID":"p","sandboxID":"","execID":""}}`, v), "unsupported operation"},
		{fmt.Sprintf(`{"version":%d,"id":4,"type":"request","request":{"operation":"sandboxes","projectID":"p","sandboxID":"","execID":"","surprise":1}}`, v), "invalid request"},
		{fmt.Sprintf(`{"version":%d,"id":5,"type":"request"}`, v), "invalid request"},
		{fmt.Sprintf(`{"version":%d,"id":6,"type":"subscribe"}`, v), "unsupported frame type"},
		{fmt.Sprintf(`{"version":%d,"id":7,"type":"request","request":{"operation":"sandboxes","projectID":"p","sandboxID":"","execID":""}}`, v+1), "Unsupported companion protocol version"},
	} {
		h.send("%s\n", tc.frame)
		if r := h.next(); r.ID == 0 || !strings.Contains(r.Error, tc.want) || r.Status != 0 || len(r.body) != 0 {
			t.Fatalf("%s: %+v", tc.frame, r.header)
		}
	}
	_ = h.in.Close()
	if err := h.finished(); err != nil {
		t.Fatal(err)
	}
}

func TestUnattributableFramesEndTheStream(t *testing.T) {
	for name, input := range map[string]string{
		"oversized": `{"version":1,"id":1,"type":"request","request":{"operation":"sandboxes","prompt":"` + strings.Repeat("x", maxFrame) + `"}}` + "\n",
		"invalid":   "{not json}\n",
		"trailing":  `{"version":1,"id":1,"type":"cancel"} {}` + "\n",
		"no id":     `{"version":1,"type":"cancel"}` + "\n",
		"unknown":   `{"version":1,"id":1,"type":"cancel","sequence":2}` + "\n",
	} {
		t.Run(name, func(t *testing.T) {
			h := serve(t, newGatedRunner())
			go func() { _, _ = io.WriteString(h.in, input) }()
			if r := h.next(); r.ID != 0 || r.Error == "" {
				t.Fatalf("stream error %+v", r.header)
			}
			if err := h.finished(); err == nil {
				t.Fatal("stream error returned nil")
			} else if name == "oversized" && !errors.Is(err, ErrFrameTooLarge) {
				t.Fatal(err)
			}
		})
	}
}

func TestEOFInsideAFrameCancelsInFlightReads(t *testing.T) {
	runner := newGatedRunner()
	h := serve(t, runner)
	h.request(1, "pending")
	waitStarted(t, runner, "pending")
	h.send(`{"version":1,"id":2,"type":"req`)
	_ = h.in.Close()
	if r := h.next(); r.ID != 1 || !strings.Contains(r.Error, "canceled") {
		t.Fatalf("in-flight reply %+v", r.header)
	}
	if r := h.next(); r.ID != 0 || !strings.Contains(r.Error, "inside a request frame") {
		t.Fatalf("stream error %+v", r.header)
	}
	if err := h.finished(); !errors.Is(err, ErrTruncatedFrame) {
		t.Fatal(err)
	}
}

func TestAdmissionIsBounded(t *testing.T) {
	runner := newGatedRunner()
	h := serve(t, runner)
	for id := uint64(1); id <= maxPending; id++ {
		h.request(id, fmt.Sprintf("b%d", id))
	}
	h.request(maxPending+1, "refused")
	if r := h.next(); r.ID != maxPending+1 || r.ErrorKind != wire.KindTransport || !strings.Contains(r.Error, "too many") {
		t.Fatalf("over-limit reply %+v", r.header)
	}
	// Only maxRunning reads reach the runner at once.
	waitStarted(t, runner, "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8")
	select {
	case box := <-runner.started:
		t.Fatalf("%s started beyond the running limit", box)
	default:
	}
	h.request(1, "duplicate")
	if r := h.next(); r.ID != 1 || !strings.Contains(r.Error, "duplicate") {
		t.Fatalf("duplicate reply %+v", r.header)
	}
	_ = h.in.Close()
	if err := h.finished(); err != nil {
		t.Fatal(err)
	}
}

func TestReaderSharesOneTransportAcrossConcurrentReads(t *testing.T) {
	var connections atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"sandboxes":[]}`)
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.Start()
	defer server.Close()
	reader, err := bridge.NewReader(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	h := serve(t, reader)
	for id := uint64(1); id <= 20; id++ {
		h.request(id, "")
		if r := h.next(); r.ID != id || r.Status != 200 || string(r.body) != `{"sandboxes":[]}` {
			t.Fatalf("reply %+v %q", r.header, r.body)
		}
	}
	if n := connections.Load(); n != 1 {
		t.Fatalf("sequential reads opened %d connections", n)
	}
}
