package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/discobox-ai/discobox/pkg/endpoint"
)

func fixtureKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}
func TestIrohIdentityAndInputValidation(t *testing.T) {
	seed := bytes.Repeat([]byte{7}, 32)
	input, _ := json.Marshal(irohStartup{Seed: seed})
	var output bytes.Buffer
	if err := runIroh("", true, strings.NewReader(string(input)+"\n"), &output); err != nil {
		t.Fatal(err)
	}
	var got struct {
		PeerID string `json:"peerID"`
	}
	if err := json.Unmarshal(output.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	want, _ := endpoint.IrohIDFromPublicKey(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	if got.PeerID != want.String() {
		t.Fatal("identity changed")
	}
	for _, raw := range []string{"discobox://" + want.String(), "iroh://" + want.String() + "?addr=127.0.0.1:1234"} {
		if _, err := parseRemote(raw); err != nil {
			t.Fatal(err)
		}
	}
	for _, raw := range []string{"discobox://", "iroh://invalid", "https://example.com", "discobox://user:password@" + want.String(), "discobox://" + want.String() + "?token=private", "discobox://" + want.String() + "?addr=example.com:123", "discobox://" + want.String() + "#fragment"} {
		if _, err := parseRemote(raw); err == nil {
			t.Fatalf("accepted invalid endpoint %q", raw)
		}
	}
	for _, data := range []string{"{}\n", strings.Repeat("x", 9000) + "\n", `{"seed":"bad"}` + "\n"} {
		if _, err := readIrohStartup(bufio.NewReaderSize(strings.NewReader(data), 8192)); err == nil {
			t.Fatal("accepted invalid seed")
		}
	}
}

// No production server, relays, discovery services, Keychain, or CLI identity.
// Exercises QUIC certificate authentication, HTTP and upgraded WebSockets
// through precisely the proxy used by the packaged app.
func TestIrohPrivateProxyHTTPWebSocketAndRevocation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	enrolled := fixtureKey(t)
	enrolledID, _ := endpoint.IrohIDFromPublicKey(enrolled.Public().(ed25519.PublicKey))
	var revoked atomic.Bool
	config := func(key ed25519.PrivateKey) endpoint.IrohConfig {
		return endpoint.IrohConfig{SecretKey: key, DisableRelay: true, DisableDiscovery: true, BindAddrs: []netip.AddrPort{netip.MustParseAddrPort("127.0.0.1:0")}}
	}
	serverCfg := config(fixtureKey(t))
	serverCfg.Authorize = func(_ context.Context, id endpoint.IrohID) error {
		if id != enrolledID || revoked.Load() {
			return errors.New("peer not enrolled")
		}
		return nil
	}
	remote, err := endpoint.NewIrohEndpoint(serverCfg)
	if err != nil {
		t.Fatal(err)
	}
	listener, _, closeRemote, err := remote.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer closeRemote()
	addrs, err := remote.DirectAddrs()
	if err != nil {
		t.Fatal(err)
	}
	remoteID, err := remote.ID()
	if err != nil {
		t.Fatal(err)
	}
	type peerContextKey struct{}
	server := &http.Server{ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
		if peer, ok := conn.(*endpoint.IrohPeerConn); ok {
			return context.WithValue(ctx, peerContextKey{}, peer.Peer)
		}
		return ctx
	}, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Context().Value(peerContextKey{}) != enrolledID || revoked.Load() {
			http.Error(w, "peer revoked", 401)
			return
		}
		if r.URL.Path == "/api/socket" {
			ws, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			defer ws.CloseNow()
			kind, data, err := ws.Read(r.Context())
			if err == nil {
				_ = ws.Write(r.Context(), kind, data)
			}
			return
		}
		if r.URL.Path == "/api/redirect" {
			http.Redirect(w, r, "https://example.invalid", 302)
			return
		}
		if r.URL.Query().Get("check") != "yes" {
			http.Error(w, "lost query", 400)
			return
		}
		data, _ := io.ReadAll(r.Body)
		_, _ = w.Write(append([]byte("reply:"), data...))
	})}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	clientCfg := config(fixtureKey(t))
	clientCfg.Issuer = enrolled
	clientEndpoint, err := endpoint.NewIrohEndpoint(clientCfg)
	if err != nil {
		t.Fatal(err)
	}
	_, _, closeClient, err := clientEndpoint.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer closeClient()
	transport, err := clientEndpoint.RoundTripper(remoteID, nil, addrs...)
	if err != nil {
		t.Fatal(err)
	}
	defer (&http.Client{Transport: transport}).CloseIdleConnections()
	var reader io.ReadCloser
	proxyDone := make(chan error, 1)
	if helper := os.Getenv("DISCOBOX_TEST_IROH_HELPER"); helper != "" {
		cmd := exec.Command(helper, "--iroh-proxy", "--endpoint", endpoint.IrohURLWithAddrs(remoteID, addrs))
		stdin, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		reader, err = cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer cmd.Process.Kill()
		if err := json.NewEncoder(stdin).Encode(irohStartup{Seed: enrolled.Seed(), DirectOnly: true}); err != nil {
			t.Fatal(err)
		}
		go func() { <-ctx.Done(); _ = stdin.Close() }()
		go func() { proxyDone <- cmd.Wait() }()
	} else {
		pipeReader, writer := io.Pipe()
		reader = pipeReader
		go func() {
			proxyDone <- servePrivateProxy(ctx, endpoint.LogicalHTTPBaseURL, transport, enrolledID.String(), writer)
			_ = writer.Close()
		}()
	}
	var ready struct {
		Endpoint string `json:"endpoint"`
	}
	if err := json.NewDecoder(reader).Decode(&ready); err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	socket := strings.TrimPrefix(ready.Endpoint, "unix://")
	info, err := os.Stat(socket)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("socket permissions: %v %v", info, err)
	}
	local, err := newBridge(ready.Endpoint, false)
	if err != nil {
		t.Fatal(err)
	}
	defer local.client.CloseIdleConnections()
	req, _ := http.NewRequestWithContext(ctx, "POST", local.base+"/api/test?check=yes", strings.NewReader("fixture"))
	res, err := local.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || string(data) != "reply:fixture" {
		t.Fatalf("HTTP round trip: %d %s", res.StatusCode, data)
	}
	ws, _, err := websocket.Dial(ctx, local.base+"/api/socket", &websocket.DialOptions{HTTPClient: local.client})
	if err != nil {
		t.Fatal(err)
	}
	if err := ws.Write(ctx, websocket.MessageBinary, []byte("terminal bytes")); err != nil {
		t.Fatal(err)
	}
	_, data, err = ws.Read(ctx)
	if err != nil || string(data) != "terminal bytes" {
		t.Fatalf("WebSocket: %q %v", data, err)
	}
	ws.CloseNow()
	if _, err := local.client.Get(local.base + "/api/redirect"); err == nil {
		t.Fatal("redirect followed")
	}
	revoked.Store(true)
	res, err = local.client.Get(local.base + "/api/test?check=yes")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 401 {
		t.Fatalf("revoked peer accepted: %d", res.StatusCode)
	}
	cancel()
	if err := <-proxyDone; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatal("private socket was not removed")
	}
}

func TestIrohUnenrolledPeerCannotReachAPI(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	offline := func() endpoint.IrohConfig {
		return endpoint.IrohConfig{SecretKey: fixtureKey(t), DisableRelay: true, DisableDiscovery: true, BindAddrs: []netip.AddrPort{netip.MustParseAddrPort("127.0.0.1:0")}}
	}
	serverCfg := offline()
	serverCfg.Authorize = func(context.Context, endpoint.IrohID) error { return errors.New("peer not enrolled") }
	serverEndpoint, err := endpoint.NewIrohEndpoint(serverCfg)
	if err != nil {
		t.Fatal(err)
	}
	listener, _, closeServer, err := serverEndpoint.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer closeServer()
	var calls atomic.Int32
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(200) })}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	clientCfg := offline()
	clientCfg.Issuer = fixtureKey(t)
	clientEndpoint, err := endpoint.NewIrohEndpoint(clientCfg)
	if err != nil {
		t.Fatal(err)
	}
	_, _, closeClient, err := clientEndpoint.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer closeClient()
	id, _ := serverEndpoint.ID()
	addrs, _ := serverEndpoint.DirectAddrs()
	transport, err := clientEndpoint.RoundTripper(id, nil, addrs...)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transport}
	defer client.CloseIdleConnections()
	request, _ := http.NewRequestWithContext(ctx, "GET", endpoint.LogicalHTTPBaseURL+"/api/test", nil)
	response, err := client.Do(request)
	if err == nil {
		response.Body.Close()
		t.Fatal("unenrolled peer reached HTTP")
	}
	if calls.Load() != 0 {
		t.Fatal("unenrolled peer reached API handler")
	}
}
