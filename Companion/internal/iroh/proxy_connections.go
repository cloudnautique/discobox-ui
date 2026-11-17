package iroh

import (
	"net"
	"sync"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
)

// http.Server forgets hijacked connections. Keep ownership at the listener
// boundary so shutdown closes HTTP and upgraded streams alike, including an
// Accept racing with shutdown. Closing the downstream stream also interrupts
// ReverseProxy's upstream copy; the proxy owns closing that upstream body.
type ownedListener struct {
	net.Listener
	mu          sync.Mutex
	closed      bool
	connections map[*ownedConnection]struct{}
}

func ownListener(listener net.Listener) *ownedListener {
	return &ownedListener{Listener: listener, connections: make(map[*ownedConnection]struct{})}
}

func (l *ownedListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		_ = c.Close()
		return nil, net.ErrClosed
	}
	owned := &ownedConnection{Conn: c, owner: l}
	l.connections[owned] = struct{}{}
	return owned, nil
}

func (l *ownedListener) Close() error {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil
	}
	l.closed = true
	connections := make([]*ownedConnection, 0, len(l.connections))
	for c := range l.connections {
		connections = append(connections, c)
	}
	l.mu.Unlock()
	diagnostics.Emit(diagnostics.Event{Event: "proxy_connections_closing", Connections: len(connections)})
	err := l.Listener.Close()
	for _, c := range connections {
		_ = c.Close()
	}
	return err
}

type ownedConnection struct {
	net.Conn
	owner *ownedListener
	once  sync.Once
	err   error
}

func (c *ownedConnection) Close() error {
	c.once.Do(func() {
		c.err = c.Conn.Close()
		c.owner.mu.Lock()
		delete(c.owner.connections, c)
		c.owner.mu.Unlock()
	})
	return c.err
}
