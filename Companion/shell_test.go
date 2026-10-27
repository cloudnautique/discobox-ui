package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestNewShellRequiresAuthorizationAndRunningBox(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	calls := 0
	b.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"runtime":{"runtimeState":"stopped"}}`)), Header: make(http.Header)}, nil
	})
	req := request{Operation: "newShell", ProjectID: "p", SandboxID: "b"}
	if _, err := b.execute(context.Background(), req); err == nil || calls != 0 {
		t.Fatal("unauthorized request reached transport")
	}
	b.allowShell = true
	if _, err := b.execute(context.Background(), req); err == nil || calls != 1 {
		t.Fatal("stopped box was not refused")
	}
}

func TestNewShellStartsOnlyNewlyCreatedExec(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowShell = true
	var routes []string
	b.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		routes = append(routes, r.Method+" "+r.URL.RequestURI())
		body := `{"id":"shell-new","status":"running","command":["bash"],"workdir":"/workspace","tty":true}`
		switch len(routes) {
		case 1:
			body = `{"runtime":{"runtimeState":"running"}}`
		case 2:
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["shell"] != true || payload["tty"] != true || payload["command"] != nil {
				t.Fatal(payload)
			}
			body = `{"exec":{"id":"shell-new","primary":false}}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	_, err := b.execute(context.Background(), request{Operation: "newShell", ProjectID: "p", SandboxID: "b", ExecID: "existing"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"GET /projects/p/sandboxes/b", "POST /api/projects/p/sandboxes/b/execs?wait=ready", "POST /api/projects/p/sandboxes/b/execs/shell-new/start", "GET /api/projects/p/sandboxes/b/execs/shell-new"}
	if strings.Join(routes, "\n") != strings.Join(want, "\n") {
		t.Fatal(routes)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestNewShellRejectsUnsafeCreatedIdentity(t *testing.T) {
	for _, body := range []string{`{"exec":{"id":"primary"}}`, `{"exec":{"id":"../other/start"}}`, `{"exec":{"id":"agent","primary":true}}`} {
		b, _ := newBridge("http://fixture", false)
		b.allowShell = true
		calls := 0
		b.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
			calls++
			if calls == 1 {
				return reply(`{"runtime":{"runtimeState":"running"}}`), nil
			}
			return reply(body), nil
		})
		_, err := b.execute(context.Background(), request{Operation: "newShell", ProjectID: "p", SandboxID: "b"})
		if err == nil || calls != 2 {
			t.Fatalf("unsafe start: %s err=%v calls=%d", body, err, calls)
		}
	}
}
