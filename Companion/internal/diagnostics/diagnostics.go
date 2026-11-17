// Package diagnostics keeps the long-lived helpers' private transport log: one
// capped, owner-only JSONL set shared by every helper process. Only
// controlled event names and reasons are recorded, never terminal content,
// URLs, headers or arbitrary error text.
package diagnostics

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	"github.com/discobox-ai/discobox/pkg/execstream/resume"
	"github.com/google/uuid"
	"golang.org/x/sys/unix"
)

// Set by the packaged build. No terminal content, URLs, headers, or arbitrary
// error strings belong in this schema. Every event name/reason is controlled.
var diagnosticBuild = "development"
var diagnosticUpstream = "unknown"
var transportDiagnostics *diagnosticLog

type Event struct {
	Retry           int    `json:"retry,omitempty"`
	HTTPStatus      int    `json:"httpStatus,omitempty"`
	RelatedSession  string `json:"relatedSession,omitempty"`
	Connections     int    `json:"connections,omitempty"`
	AcceptedBytes   int64  `json:"acceptedActionBytes,omitempty"`
	SentBytes       int64  `json:"sentActionBytes,omitempty"`
	PendingBytes    int64  `json:"pendingActionBytes,omitempty"`
	AckAgeMS        int64  `json:"ackAgeMs,omitempty"`
	Time            string `json:"time"`
	ElapsedMS       int64  `json:"elapsedMs"`
	Session         string `json:"session"`
	PID             int    `json:"pid"`
	Component       string `json:"component"`
	Endpoint        string `json:"endpointHash"`
	Connection      string `json:"connection,omitempty"`
	Project         string `json:"project,omitempty"`
	Box             string `json:"box,omitempty"`
	Exec            string `json:"exec,omitempty"`
	Build           string `json:"build"`
	Upstream        string `json:"upstream"`
	Event           string `json:"event"`
	Reason          string `json:"reason,omitempty"`
	Generation      int64  `json:"generation,omitempty"`
	Received        int64  `json:"receivedBytes,omitempty"`
	Delivered       int64  `json:"deliveredBytes,omitempty"`
	Queue           int64  `json:"queuedBytes,omitempty"`
	ReadAgeMS       int64  `json:"readAgeMs,omitempty"`
	WriteAgeMS      int64  `json:"writeAgeMs,omitempty"`
	DurationMS      int64  `json:"durationMs,omitempty"`
	Dropped         uint64 `json:"droppedRecords,omitempty"`
	RelatedEndpoint string `json:"relatedEndpointHash,omitempty"`
	Path            string `json:"path,omitempty"`
}

type diagnosticLog struct {
	base    Event
	start   time.Time
	events  chan Event
	stop    chan struct{}
	done    chan struct{}
	once    sync.Once
	dropped atomic.Uint64
	sink    func([]byte) error
}

func newDiagnosticLog(base Event, sink func([]byte) error) *diagnosticLog {
	d := &diagnosticLog{base: base, start: time.Now(), events: make(chan Event, 128), stop: make(chan struct{}), done: make(chan struct{}), sink: sink}
	go d.run()
	return d
}
func (d *diagnosticLog) emit(e Event) {
	if d == nil {
		return
	}
	select {
	case <-d.stop:
		return
	default:
	}
	e.Time = time.Now().UTC().Format(time.RFC3339Nano)
	e.ElapsedMS = time.Since(d.start).Milliseconds()
	select {
	case d.events <- e:
	default:
		d.dropped.Add(1)
	}
}
func (d *diagnosticLog) write(e Event) {
	e.Session, e.PID, e.Component = d.base.Session, d.base.PID, d.base.Component
	e.Endpoint, e.Connection = d.base.Endpoint, d.base.Connection
	e.Project, e.Box, e.Exec = d.base.Project, d.base.Box, d.base.Exec
	e.Build, e.Upstream = d.base.Build, d.base.Upstream
	e.Dropped = d.dropped.Swap(0)
	data, err := json.Marshal(e)
	if err != nil || d.sink(append(data, '\n')) != nil {
		d.dropped.Add(e.Dropped + 1)
	}
}
func (d *diagnosticLog) run() {
	defer close(d.done)
	for {
		select {
		case e := <-d.events:
			d.write(e)
		case <-d.stop:
			for {
				select {
				case e := <-d.events:
					d.write(e)
				default:
					return
				}
			}
		}
	}
}
func (d *diagnosticLog) close() {
	if d == nil {
		return
	}
	d.once.Do(func() { close(d.stop) })
	// A stuck filesystem must not delay detach or process exit indefinitely.
	select {
	case <-d.done:
	case <-time.After(250 * time.Millisecond):
	}
}
func Emit(e Event)                 { transportDiagnostics.emit(e) }
func EndpointHash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:12]) }
func safeDiagnosticID(s string) string {
	if len(s) > 128 {
		return "invalid"
	}
	for _, c := range s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			return "invalid"
		}
	}
	return s
}
func Start(component, endpoint, connection string, req wire.Request) func() {
	home, err := os.UserHomeDir()
	if err != nil {
		return func() {}
	}
	dir := diagnosticDirectory(home, runtime.GOOS)
	return StartWithSink(Event{Session: uuid.NewString(), PID: os.Getpid(), Component: component,
		Endpoint: EndpointHash(endpoint), Connection: safeDiagnosticID(connection), Project: safeDiagnosticID(req.ProjectID), Box: safeDiagnosticID(req.SandboxID), Exec: safeDiagnosticID(req.ExecID), Build: diagnosticBuild, Upstream: diagnosticUpstream},
		func(data []byte) error { return appendDiagnostic(dir, data, 2<<20, 4) })
}

// StartWithSink is Start with a caller-supplied record sink and base event.
func StartWithSink(base Event, sink func([]byte) error) func() {
	transportDiagnostics = newDiagnosticLog(base, sink)
	Emit(Event{Event: "helper_started"})
	return func() { Emit(Event{Event: "helper_stopped"}); transportDiagnostics.close() }
}

// Enabled reports whether this process records diagnostics.
func Enabled() bool { return transportDiagnostics != nil }

// Session is this process's diagnostic session ID, or "" when disabled.
func Session() string {
	if transportDiagnostics == nil {
		return ""
	}
	return transportDiagnostics.base.Session
}

func diagnosticDirectory(home, operatingSystem string) string {
	// The server may already own Logs/Discobox with normal 0755 permissions.
	// Keep UI diagnostics private without changing that shared directory or
	// silently rejecting every record because the server created it first.
	dir := filepath.Join(home, "Library", "Logs", "Discobox", "diagnostics")
	if operatingSystem != "darwin" {
		dir = filepath.Join(home, ".local", "state", "discobox-ui", "logs")
	}
	return dir
}
func Reason(err error) string {
	if err == nil {
		return "ok"
	}
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline"
	case errors.Is(err, io.EOF):
		return "eof"
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "unexpected_eof"
	case errors.Is(err, net.ErrClosed):
		return "closed"
	}
	var n net.Error
	if errors.As(err, &n) && n.Timeout() {
		return "timeout"
	}
	return "failure"
}

// One capped log set for all helper processes, not an unbounded file per
// terminal. The lock is advisory/nonblocking; contention drops a record.
func appendDiagnostic(dir string, data []byte, limit int64, files int) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	var ds unix.Stat_t
	if unix.Lstat(dir, &ds) != nil || !info.IsDir() || ds.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return errors.New("unsafe log directory")
	}
	lock, err := privateLogFile(filepath.Join(dir, "transport.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return err
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	path := filepath.Join(dir, "transport.jsonl")
	f, err := privateLogFile(path)
	if err != nil {
		return err
	}
	info, err = f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	if info.Size()+int64(len(data)) > limit {
		f.Close()
		for i := files - 1; i >= 1; i-- {
			old := path
			if i > 1 {
				old += "." + strconv.Itoa(i-1)
			}
			next := path + "." + strconv.Itoa(i)
			if err := os.Rename(old, next); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
		f, err = privateLogFile(path)
		if err != nil {
			return err
		}
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}
func privateLogFile(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_WRONLY|unix.O_APPEND|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	var st unix.Stat_t
	if unix.Fstat(fd, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Uid != uint32(os.Getuid()) || st.Nlink != 1 || st.Mode&0077 != 0 {
		unix.Close(fd)
		return nil, errors.New("unsafe log file")
	}
	return os.NewFile(uintptr(fd), path), nil
}

// Upstream transport messages are reduced to known event categories. Do not
// persist the raw line: native/HTTP errors can contain URLs or remote text.
// Path selection is not exposed here; a discovered direct path is not proof
// that traffic switched to it.
type IrohWriter struct{}

func (IrohWriter) Write(p []byte) (int, error) {
	s := string(p)
	event := "iroh_transport"
	for _, category := range []string{"bind:", "relay:", "connect:", "stream:", "accept:"} {
		if strings.Contains(s, category) {
			event = "iroh_" + strings.TrimSuffix(category, ":")
			break
		}
	}
	reason := "event"
	if strings.Contains(s, "failed") || strings.Contains(s, "unavailable") {
		reason = "failure"
	}
	if strings.Contains(s, " connected in ") {
		reason = "connected"
	}
	Emit(Event{Event: event, Reason: reason})
	return len(p), nil
}

// Aggregate action metadata instead of recording per-keystroke events.
func ObserveAttachActions(ctx context.Context) context.Context {
	if transportDiagnostics == nil {
		return ctx
	}
	var accepted, sent, pending, ackAt atomic.Int64
	started := time.Now()
	observed := resume.WithObserver(ctx, resume.ObserverFunc(func(e resume.ActionEvent) {
		pending.Store(int64(e.PendingBytes))
		switch e.Phase {
		case resume.ActionAccepted:
			accepted.Add(int64(e.PayloadBytes))
		case resume.ActionPhysicalWrite, resume.ActionRetransmitted:
			sent.Add(int64(e.PayloadBytes))
			if e.Err != nil {
				Emit(Event{Event: "attach_action_write_failed", Reason: Reason(e.Err)})
			}
		case resume.ActionAcknowledged:
			ackAt.Store(time.Since(started).Milliseconds())
		}
	}))
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				Emit(Event{Event: "attach_actions", AcceptedBytes: accepted.Load(), SentBytes: sent.Load(), PendingBytes: pending.Load(), AckAgeMS: time.Since(started).Milliseconds() - ackAt.Load()})
			}
		}
	}()
	return observed
}
