package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type fakeTransport func(*http.Request) (*http.Response, error)

func (f fakeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func reply(body string) *http.Response {
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestPassiveOperationsCannotReachLifecycleOrActiveReads(t *testing.T) {
	for _, op := range []string{"start", "stop", "restart", "delete", "shutdown", "attach", "logs", "files", "resources", "create", "approve"} {
		_, _, _, err := route(request{Operation: op, ProjectID: "p", SandboxID: "s", ExecID: "e"}, true)
		if err == nil {
			t.Errorf("accepted forbidden operation %q", op)
		}
	}
	for _, op := range []string{"defaultProject", "sandboxes", "execs", "services", "screen"} {
		method, _, _, err := route(request{Operation: op, ProjectID: "p", SandboxID: "s", ExecID: "e"}, false)
		if err != nil || method != "GET" {
			t.Errorf("passive %s: method=%q error=%v", op, method, err)
		}
	}
}

func TestRejectPathInjectionAndVirtualPrimary(t *testing.T) {
	for _, id := range []string{"../shutdown", "a/b", "a%2fb", "?x", "", "primary"} {
		_, _, _, err := route(request{Operation: "screen", ProjectID: "p", SandboxID: "s", ExecID: id}, false)
		if err == nil {
			t.Errorf("accepted unsafe exec %q", id)
		}
	}
}

func TestDefaultProjectAlwaysUsesServerAlias(t *testing.T) {
	method, path, _, err := route(request{Operation: "defaultProject", ProjectID: "other"}, false)
	if err != nil || method != "GET" || path != "/projects/default" {
		t.Fatalf("wrong default resolution: %s %s %v", method, path, err)
	}
	if _, _, _, err := route(request{Operation: "projects"}, false); err == nil {
		t.Fatal("project enumeration is still exposed")
	}
}

func TestInputRequiresOptInAndExactWireShape(t *testing.T) {
	text, key := "hello", "Enter"
	req := request{Operation: "input", ProjectID: "p", SandboxID: "s", ExecID: "e", Input: []inputPart{{Text: &text}, {Key: &key}}}
	if _, _, _, err := route(req, false); err == nil {
		t.Fatal("input accepted without opt-in")
	}
	method, path, body, err := route(req, true)
	if err != nil {
		t.Fatal(err)
	}
	if method != "POST" || path != "/api/projects/p/sandboxes/s/execs/e/input" {
		t.Fatalf("wrong route: %s %s", method, path)
	}
	if string(body) != `{"input":[{"text":"hello"},{"key":"Enter"}]}` {
		t.Fatalf("wrong body: %s", body)
	}
	req.Input = []inputPart{{Text: &text, Key: &key}}
	if _, _, _, err := route(req, true); err == nil {
		t.Fatal("accepted ambiguous input part")
	}
}

func TestInputPreflightRefusesStoppedOrCachedTerminal(t *testing.T) {
	for _, scenario := range []struct{ name, box, exec string }{
		{"stopped", `{"runtime":{"runtimeState":"stopped"}}`, `{"status":"running","tty":true}`},
		{"cached", `{"runtime":{"runtimeState":"running"}}`, `{"status":"running","tty":true,"observedAt":"2026-10-26T10:00:00Z"}`},
		{"exited", `{"runtime":{"runtimeState":"running"}}`, `{"status":"exited","tty":true}`},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			b := &bridge{base: "http://fixture", allowInput: true, client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
				if r.Method != "GET" {
					t.Fatal("sent a write after failed preflight")
				}
				if strings.HasPrefix(r.URL.Path, "/api/") {
					return reply(scenario.exec), nil
				}
				return reply(scenario.box), nil
			})}}
			text := "hello"
			_, err := b.execute(context.Background(), request{Operation: "input", ProjectID: "p", SandboxID: "s", ExecID: "e", Input: []inputPart{{Text: &text}}})
			if err == nil {
				t.Fatal("input accepted")
			}
		})
	}
}

func TestExplicitInputIsSentOnce(t *testing.T) {
	writes := 0
	b := &bridge{base: "http://fixture", allowInput: true, client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "POST" {
			writes++
			if r.Header.Get("Content-Type") != "application/json" {
				t.Fatal("missing content type")
			}
			return reply(`{"resumeAfter":"position"}`), nil
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			return reply(`{"status":"running","tty":true}`), nil
		}
		return reply(`{"runtime":{"runtimeState":"running"}}`), nil
	})}}
	text := "hello"
	result, err := b.execute(context.Background(), request{Operation: "input", ProjectID: "p", SandboxID: "s", ExecID: "e", Input: []inputPart{{Text: &text}}})
	if err != nil || result.Status != 200 || writes != 1 {
		t.Fatalf("writes=%d result=%+v err=%v", writes, result, err)
	}
}

func TestPassiveScreenDoesNotPreflightOrWrite(t *testing.T) {
	calls := 0
	b := &bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || r.URL.Path != "/api/projects/p/sandboxes/s/execs/e/screen" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL)
		}
		return reply(`{"lines":["saved"],"observedAt":"past"}`), nil
	})}}
	_, err := b.execute(context.Background(), request{Operation: "screen", ProjectID: "p", SandboxID: "s", ExecID: "e"})
	if err != nil || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestEndpointValidationAndRedirectPolicy(t *testing.T) {
	for _, endpoint := range []string{"iroh://peer", "https://user:pass@host", "http://host?x=y", "unix://host/path", "http://"} {
		if _, err := newBridge(endpoint, false); err == nil {
			t.Errorf("accepted %q", endpoint)
		}
	}
	b, err := newBridge("unix://", false)
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
	before := response{Version: 1, Status: 200, Body: []byte(`{"projects":null}`)}
	encoded, err := json.Marshal(before)
	if err != nil {
		t.Fatal(err)
	}
	var after response
	if err := json.Unmarshal(encoded, &after); err != nil {
		t.Fatal(err)
	}
	if string(after.Body) != string(before.Body) {
		t.Fatal("body changed")
	}
}
