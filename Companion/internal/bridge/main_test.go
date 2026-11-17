package bridge

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

type fakeTransport func(*http.Request) (*http.Response, error)

func (f fakeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func reply(body string) *http.Response {
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestPassiveOperationsCannotReachLifecycleOrActiveReads(t *testing.T) {
	for _, op := range []string{"start", "stop", "restart", "delete", "shutdown", "attach", "logs", "files", "resources", "create", "approve"} {
		_, _, _, err := route(wire.Request{Operation: op, ProjectID: "p", SandboxID: "s", ExecID: "e"})
		if err == nil {
			t.Errorf("accepted forbidden operation %q", op)
		}
	}
	for _, op := range []string{"defaultProject", "sandboxes", "execs", "services", "screen"} {
		method, _, _, err := route(wire.Request{Operation: op, ProjectID: "p", SandboxID: "s", ExecID: "e"})
		if err != nil || method != "GET" {
			t.Errorf("passive %s: method=%q error=%v", op, method, err)
		}
	}
}

func TestRejectPathInjectionAndVirtualPrimary(t *testing.T) {
	for _, id := range []string{"../shutdown", "a/b", "a%2fb", "?x", "", "primary"} {
		_, _, _, err := route(wire.Request{Operation: "screen", ProjectID: "p", SandboxID: "s", ExecID: id})
		if err == nil {
			t.Errorf("accepted unsafe exec %q", id)
		}
	}
}

func TestDefaultProjectAlwaysUsesServerAlias(t *testing.T) {
	method, path, _, err := route(wire.Request{Operation: "defaultProject", ProjectID: "other"})
	if err != nil || method != "GET" || path != "/projects/default" {
		t.Fatalf("wrong default resolution: %s %s %v", method, path, err)
	}
	if _, _, _, err := route(wire.Request{Operation: "projects"}); err == nil {
		t.Fatal("project enumeration is still exposed")
	}
}

func TestLegacyInputIsRejectedWithoutAnHTTPRequest(t *testing.T) {
	b := &Bridge{client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		t.Fatal("removed input operation made an HTTP request")
		return nil, nil
	})}}
	if _, err := b.execute(context.Background(), wire.Request{Operation: "input", ProjectID: "p", SandboxID: "s", ExecID: "e"}); err == nil {
		t.Fatal("accepted removed input operation")
	}
}

func TestPassiveScreenDoesNotPreflightOrWrite(t *testing.T) {
	calls := 0
	b := &Bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || r.URL.Path != "/api/projects/p/sandboxes/s/execs/e/screen" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL)
		}
		return reply(`{"lines":["saved"],"observedAt":"past"}`), nil
	})}}
	_, err := b.execute(context.Background(), wire.Request{Operation: "screen", ProjectID: "p", SandboxID: "s", ExecID: "e"})
	if err != nil || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestEndpointValidationAndRedirectPolicy(t *testing.T) {
	for _, endpoint := range []string{"iroh://peer", "https://user:pass@host", "http://host?x=y", "unix://host/path", "http://"} {
		if _, err := New(endpoint); err == nil {
			t.Errorf("accepted %q", endpoint)
		}
	}
	b, err := New("unix://")
	if err != nil {
		t.Fatal(err)
	}
	if b.client.CheckRedirect(&http.Request{}, nil) == nil {
		t.Fatal("redirects allowed")
	}
	t.Setenv("XDG_RUNTIME_DIR", "/fixture/runtime")
	if got := defaultSocket(); got != "/fixture/runtime/discobox/server.sock" {
		t.Fatalf("wrong socket: %s", got)
	}
}

func TestResponseEnvelopeRoundTripsBinaryJSON(t *testing.T) {
	before := wire.Response{Version: wire.ProtocolVersion, Status: 200, Body: []byte(`{"projects":null}`)}
	encoded, err := json.Marshal(before)
	if err != nil {
		t.Fatal(err)
	}
	var after wire.Response
	if err := json.Unmarshal(encoded, &after); err != nil {
		t.Fatal(err)
	}
	if string(after.Body) != string(before.Body) {
		t.Fatal("body changed")
	}
}
