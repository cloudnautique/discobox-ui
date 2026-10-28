package main

// The GUI owns the enrollment key. It sends a seed over stdin; this process
// owns one ephemeral transport and a private Unix HTTP proxy for all helpers.
import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/discobox-ai/discobox/pkg/endpoint"
)

type irohStartup struct {
	Seed       []byte   `json:"seed"`
	RelayURLs  []string `json:"relayURLs,omitempty"`
	DirectOnly bool     `json:"directOnly,omitempty"`
}

func parseRemote(raw string) (endpoint.Endpoint, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return endpoint.Endpoint{}, errors.New("invalid remote address")
	}
	if u.User != nil || u.Fragment != "" || u.Opaque != "" {
		return endpoint.Endpoint{}, errors.New("remote address must not contain credentials or a fragment")
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return endpoint.Endpoint{}, errors.New("invalid remote address query")
	}
	for key, values := range query {
		if key != "addr" {
			return endpoint.Endpoint{}, errors.New("only direct address hints (?addr=) are supported")
		}
		for _, value := range values {
			if _, err := netip.ParseAddrPort(value); err != nil {
				return endpoint.Endpoint{}, errors.New("invalid direct address hint")
			}
		}
	}
	parsed, err := endpoint.Parse(raw)
	if err != nil {
		return endpoint.Endpoint{}, err
	}
	if parsed.Scheme != "iroh" {
		return endpoint.Endpoint{}, errors.New("enter the server's discobox://d1-… peer address")
	}
	if _, err := parsed.IrohID(); err != nil {
		return endpoint.Endpoint{}, err
	}
	return parsed, nil
}

func readIrohStartup(reader *bufio.Reader) (irohStartup, error) {
	line, err := reader.ReadSlice('\n') // bounded by the reader's 8 KiB buffer
	if err != nil {
		return irohStartup{}, errors.New("invalid identity handshake")
	}
	var cfg irohStartup
	if err := json.Unmarshal(line, &cfg); err != nil || len(cfg.Seed) != ed25519.SeedSize {
		return cfg, errors.New("invalid identity seed")
	}
	for _, raw := range cfg.RelayURLs {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return cfg, errors.New("custom relay must be an HTTPS URL without credentials")
		}
	}
	return cfg, nil
}

func runIroh(raw string, identityOnly bool, input io.Reader, output io.Writer) error {
	reader := bufio.NewReaderSize(input, 8192)
	cfg, err := readIrohStartup(reader)
	if err != nil {
		return err
	}
	issuer := ed25519.NewKeyFromSeed(cfg.Seed)
	clear(cfg.Seed)
	id, err := endpoint.IrohIDFromPublicKey(issuer.Public().(ed25519.PublicKey))
	if err != nil {
		return err
	}
	if identityOnly {
		return json.NewEncoder(output).Encode(map[string]string{"peerID": id.String()})
	}
	// Packaged builds load the signed library from their own bundle. Development
	// builds use iroh-go's embedded library and cache.
	if executable, e := os.Executable(); e == nil {
		library := filepath.Join(filepath.Dir(executable), "..", "Frameworks", "libiroh_go.dylib")
		if info, e := os.Stat(library); e == nil && info.Mode().IsRegular() {
			if e := os.Setenv("IROH_GO_LIBRARY", library); e != nil {
				return e
			}
		}
	}
	parsed, err := parseRemote(raw)
	if err != nil {
		return err
	}
	if cfg.DirectOnly && len(parsed.IrohAddrs) == 0 {
		return errors.New("direct-only connections require an ?addr=IP:port hint in the server address")
	}
	_, ephemeral, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := endpoint.ConfigureIroh(endpoint.IrohConfig{SecretKey: ephemeral, Issuer: issuer, RelayURLs: cfg.RelayURLs, DisableRelay: cfg.DirectOnly, DisableDiscovery: cfg.DirectOnly}); err != nil {
		return fmt.Errorf("initialize Iroh: %w", err)
	}
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	base.MaxResponseHeaderBytes = 64 << 10
	// The calling helper owns each request deadline; long box actions and
	// transfers must not inherit a short proxy-wide response timeout.
	base.ResponseHeaderTimeout = 0
	baseURL, client, err := endpoint.HTTPClient(parsed, base)
	if err != nil {
		return err
	}
	defer client.CloseIdleConnections()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	go func() { _, _ = io.Copy(io.Discard, reader); stop() }()
	return servePrivateProxy(ctx, baseURL, client.Transport, id.String(), output)
}

func servePrivateProxy(ctx context.Context, baseURL string, transport http.RoundTripper, peerID string, output io.Writer) error {
	// Short path avoids Darwin's 104-byte Unix socket limit. MkdirTemp uses 0700.
	dir, err := os.MkdirTemp("/tmp", "discobox-iroh-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "api.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.Chmod(socket, 0600); err != nil {
		return err
	}
	target, err := url.Parse(baseURL)
	if err != nil {
		return err
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.Host = target.Host
			r.Out.Header.Del("Forwarded")
			r.Out.Header.Del("X-Forwarded-For")
			r.Out.Header.Del("X-Forwarded-Host")
			r.Out.Header.Del("X-Forwarded-Proto")
		},
		Transport:     transport,
		FlushInterval: -1,
		ErrorLog:      log.New(io.Discard, "", 0),
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "Remote Discobox is unreachable or refused this peer. Check its Iroh listener, network, and peer enrollment."})
		},
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		proxy.ServeHTTP(w, r)
	}), ReadHeaderTimeout: 10 * time.Second, MaxHeaderBytes: 64 << 10}
	defer server.Close()
	if err := json.NewEncoder(output).Encode(map[string]string{"endpoint": "unix://" + socket, "peerID": peerID}); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
		return nil
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
