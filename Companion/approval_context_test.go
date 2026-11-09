package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/pkg/bindingplan"
)

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
