package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/pkg/bindingplan"
)

func TestApprovalContextWireEnvelope(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" {
					t.Errorf("preview mutated %s", r.URL)
				}
				w.Header().Set("Content-Type", "application/json")
				if status != http.StatusOK {
					w.WriteHeader(status)
					io.WriteString(w, `{"detail":"Request no longer exists"}`)
					return
				}
				switch r.URL.Path {
				case "/projects/p/secret-requests/ask":
					io.WriteString(w, `{"id":"ask","sandboxId":"requester","envName":"TOKEN","status":"pending","use":{}}`)
				case "/projects/p/secrets":
					io.WriteString(w, `{"secrets":[]}`)
				case "/projects/p/bound-secrets":
					io.WriteString(w, `{"boundSecrets":[]}`)
				case "/projects/p/secret-bindings":
					io.WriteString(w, `{"secretBindings":[]}`)
				default:
					t.Errorf("unexpected preview route %s", r.URL)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			out := response{Version: 1}
			input := `{"operation":"approvalContext","projectID":"p","requestID":"ask"}`
			if err := runManaged(server.URL, false, false, false, strings.NewReader(input), &out); err != nil {
				t.Fatal(err)
			}
			wire, err := json.Marshal(out)
			if err != nil {
				t.Fatal(err)
			}
			var decoded response
			if err = json.Unmarshal(wire, &decoded); err != nil || decoded.Version != 1 || decoded.Status != status || !json.Valid(decoded.Body) {
				t.Fatalf("invalid approval envelope: version=%d status=%d err=%v", decoded.Version, decoded.Status, err)
			}
			if status == http.StatusOK {
				var review approvalContext
				if err = json.Unmarshal(decoded.Body, &review); err != nil || review.Fingerprint == "" {
					t.Fatalf("missing credential review: %v", err)
				}
			} else if !strings.Contains(string(decoded.Body), "Request no longer exists") {
				t.Fatal("API error detail was lost")
			}
		})
	}
}

func TestCredentialReviewUsesRequesterAndCanonicalCombinedPlan(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	changed := false
	writes := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		body := `{}`
		switch r.URL.Path {
		case "/projects/p/secret-requests/ask":
			body = `{"id":"ask","sandboxId":"requester","envName":"TOKEN","status":"pending","use":{},"delegate":{}}`
		case "/projects/p/secrets":
			body = `{"$schema":"schema","secrets":[{"id":"sec","maxBindingTTLSeconds":3600}]}`
			if changed {
				body = `{"secrets":[{"id":"sec","maxBindingTTLSeconds":900}]}`
			}
		case "/projects/p/bound-secrets":
			if r.URL.Query().Get("target") != "requester" || r.URL.Query().Get("targetKind") != "sandbox" {
				t.Fatalf("retargeted context %s", r.URL)
			}
			body = `{"boundSecrets":[]}`
		case "/projects/p/secret-bindings":
			if r.URL.Query().Get("target") != "requester" {
				t.Fatalf("wrong bindings %s", r.URL)
			}
			body = `{"secretBindings":[{"id":"both","secretId":"sec","targetKind":"sandbox","targetId":"requester","envVar":"TOKEN","use":true,"delegate":true,"createdAt":"2026-11-01T00:00:00Z"}]}`
		case "/projects/p/secret-requests/ask/approve":
			writes++
			raw, _ := io.ReadAll(r.Body)
			if strings.Contains(string(raw), "contextFingerprint") || !strings.Contains(string(raw), `"secretId":"sec"`) {
				t.Fatalf("wrong server body %s", raw)
			}
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	candidate := json.RawMessage(`{"secretId":"sec","use":{"decision":"approve","as":"replace"},"delegate":{"decision":"approve"}}`)
	req := request{Operation: "approvalContext", ProjectID: "p", SandboxID: "unrelated-selected-box", RequestID: "ask", Payload: candidate}
	result, err := b.execute(t.Context(), req)
	if err != nil {
		t.Fatal(err)
	}
	var review approvalContext
	if err = json.Unmarshal(result.Body, &review); err != nil {
		t.Fatal(err)
	}
	if review.Use.Steps[0].Fate != bindingplan.LosesUse || review.Delegate.Steps[0].Fate != bindingplan.Updated {
		t.Fatalf("combined effect disagrees with server: %+v", review)
	}
	req.Operation = "answer"
	req.Kind = "credential"
	req.Action = "approve"
	req.Payload, _ = json.Marshal(map[string]any{"approval": candidate, "contextFingerprint": review.Fingerprint})
	changed = true
	if _, err = b.execute(t.Context(), req); err == nil || writes != 0 {
		t.Fatal("stale review wrote an approval")
	}
	changed = false
	if _, err = b.execute(t.Context(), req); err != nil || writes != 1 {
		t.Fatalf("fresh review writes=%d err=%v", writes, err)
	}
	req.Payload = candidate
	if _, err = b.execute(t.Context(), req); err == nil || writes != 1 {
		t.Fatal("approval without binding review accepted")
	}
}
