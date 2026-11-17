package iroh

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
)

func TestPrivateProxyCancellationClosesLiveUpgrades(t *testing.T) {
	// Do not exit a process or close the client first: that would mask leaked
	// hijacked connections. Flood output while the downstream does not read.
	upstreamDone := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer close(upstreamDone)
		defer ws.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		data := make([]byte, 256<<10)
		for {
			if ws.Write(ctx, websocket.MessageBinary, data) != nil {
				return
			}
		}
	}))
	defer upstream.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	reader, writer := io.Pipe()
	defer reader.Close()
	done := make(chan error, 1)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	defer transport.CloseIdleConnections()
	go func() { done <- servePrivateProxy(ctx, upstream.URL, transport, "fixture", writer); writer.Close() }()
	var ready struct {
		Endpoint string `json:"endpoint"`
	}
	if err := json.NewDecoder(reader).Decode(&ready); err != nil {
		t.Fatal(err)
	}
	local, err := bridge.New(ready.Endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer local.HTTPClient().CloseIdleConnections()
	ws, _, err := websocket.Dial(t.Context(), local.BaseURL()+"/api/socket", &websocket.DialOptions{HTTPClient: local.HTTPClient()})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("proxy shutdown hung")
	}
	select {
	case <-upstreamDone:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream upgraded stream survived cancellation")
	}
	// Drain any already buffered frame, then require closure, not a timeout.
	readCtx, stop := context.WithTimeout(t.Context(), time.Second)
	defer stop()
	for {
		if _, _, err := ws.Read(readCtx); err != nil {
			break
		}
	}
	if readCtx.Err() != nil {
		t.Fatal("downstream upgraded stream survived cancellation")
	}
	if _, err := os.Stat(strings.TrimPrefix(ready.Endpoint, "unix://")); !os.IsNotExist(err) {
		t.Fatal("proxy socket remains")
	}
}

type lateAcceptListener struct {
	accepted net.Conn
	release  chan struct{}
}

func (l *lateAcceptListener) Accept() (net.Conn, error) { <-l.release; return l.accepted, nil }
func (*lateAcceptListener) Close() error                { return nil }
func (*lateAcceptListener) Addr() net.Addr              { return &net.UnixAddr{Name: "fixture", Net: "unix"} }

func TestProxyOwnerClosesConnectionAcceptedDuringShutdown(t *testing.T) {
	for range 25 {
		local, peer := net.Pipe()
		base := &lateAcceptListener{accepted: local, release: make(chan struct{})}
		listener := ownListener(base)
		accepted := make(chan error, 1)
		go func() { _, err := listener.Accept(); accepted <- err }()
		if err := listener.Close(); err != nil {
			t.Fatal(err)
		}
		close(base.release)
		if err := <-accepted; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("late accept escaped shutdown: %v", err)
		}
		peer.SetWriteDeadline(time.Now().Add(time.Second))
		if _, err := peer.Write([]byte("probe")); !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("late accepted socket still open: %v", err)
		}
		peer.Close()
		if err := listener.Close(); err != nil {
			t.Fatal("repeated close failed")
		}
	}
}
