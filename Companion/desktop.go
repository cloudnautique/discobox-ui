package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"syscall"
)

//go:embed desktop_bridge.js
var desktopBridgeJS []byte

func desktopProxy(raw string) (http.Handler, error) {
	target, err := url.Parse(raw)
	if err != nil || target.Scheme != "http" || target.Hostname() != "127.0.0.1" || target.User != nil || target.RawQuery != "" || target.Fragment != "" || (target.Path != "" && target.Path != "/") {
		return nil, errors.New("desktop requires a local HTTP forward")
	}
	port, err := strconv.Atoi(target.Port())
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("invalid desktop port")
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	proxy.Transport = transport
	director := proxy.Director
	proxy.Director = func(r *http.Request) { director(r); r.Header.Del("Accept-Encoding") }
	proxy.ModifyResponse = func(r *http.Response) error {
		// Only adapt the existing desktop module; retain its resize/annotation UI.
		if r.Request.URL.Path != "/app.js" || r.StatusCode != 200 {
			return nil
		}
		defer r.Body.Close()
		body, err := io.ReadAll(io.LimitReader(r.Body, 2<<20+1))
		if err != nil {
			return err
		}
		if len(body) > 2<<20 {
			return errors.New("desktop module is too large")
		}
		body = append(append(body, '\n'), desktopBridgeJS...)
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		r.Header.Set("Content-Length", strconv.Itoa(len(body)))
		r.Header.Del("ETag")
		r.Header.Del("Content-Encoding")
		r.Header.Set("Cache-Control", "no-store")
		return nil
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Reject browser requests for this listener through an unrelated hostname.
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil || host != "127.0.0.1" {
			http.Error(w, "invalid host", http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	}), nil
}

func runDesktop(raw string, input io.Reader, output io.Writer) error {
	handler, err := desktopProxy(raw)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	defer listener.Close()
	// Hijacked WebSockets are not closed by http.Server.Close. Tie their requests
	// to this lifetime so proxy copying also terminates when the app closes.
	server := &http.Server{Handler: handler, BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _, _ = io.Copy(io.Discard, input); cancel() }()
	go func() { <-ctx.Done(); _ = server.Close() }()
	if err := json.NewEncoder(output).Encode(map[string]string{"url": "http://" + listener.Addr().String()}); err != nil {
		return err
	}
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
