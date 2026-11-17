package bridge

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// ReadServerPermissions are the only permission classes the persistent read
// companion serves; protocol.json publishes them for the Swift client.
var ReadServerPermissions = []permission{permissionRead}

var errReadOnly = errors.New("the persistent companion serves only read operations")

// Reader serves read operations for the persistent read companion: one
// endpoint and one HTTP transport shared by concurrent reads, so routine
// polling reuses its connections. It never holds the manage or shell flag, so
// dispatch refuses a write even if the registry check were bypassed.
type Reader struct {
	base *Bridge
	mu   sync.Mutex
	// One client per (streaming, slowHeaders) shape. One-shot mode mutates
	// its single client per operation; concurrent reads cannot share that.
	shaped map[[2]bool]*Bridge
}

// NewReader validates endpoint like New.
func NewReader(endpoint string) (*Reader, error) {
	b, err := New(endpoint)
	if err != nil {
		return nil, err
	}
	return &Reader{base: b, shaped: map[[2]bool]*Bridge{{false, false}: b}}, nil
}

func readOperation(req wire.Request) (operation, error) {
	op, err := lookupOperation(req.Operation)
	if err != nil {
		return operation{}, err
	}
	if op.permission != permissionRead {
		return operation{}, errReadOnly
	}
	return op, nil
}

// Deadline is the registry's deadline for req, or an error for an unknown or
// non-read operation, checked before the request is queued.
func (r *Reader) Deadline(req wire.Request) (time.Duration, error) {
	op, err := readOperation(req)
	if err != nil {
		return 0, err
	}
	return op.deadlineFor(req), nil
}

// Run serves one read; the caller applies Deadline to ctx.
func (r *Reader) Run(ctx context.Context, req wire.Request) (wire.Response, error) {
	op, err := readOperation(req)
	if err != nil {
		return wire.Response{}, err
	}
	return r.bridgeFor(op).dispatch(ctx, op, req)
}

// Close releases the shared transports' idle connections.
func (r *Reader) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, b := range r.shaped {
		b.client.CloseIdleConnections()
	}
}

func (r *Reader) bridgeFor(op operation) *Bridge {
	key := [2]bool{op.streaming, op.slowHeaders}
	r.mu.Lock()
	defer r.mu.Unlock()
	if b, ok := r.shaped[key]; ok {
		return b
	}
	client := *r.base.client
	if op.slowHeaders {
		// Only a slow-header read gets a transport of its own; the others
		// share the base transport and its connection pool.
		client.Transport = client.Transport.(*http.Transport).Clone()
	}
	op.configure(&client)
	b := &Bridge{client: &client, base: r.base.base}
	r.shaped[key] = b
	return b
}
