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

func TestDelegatedBindingConflictIsReviewedBeforeAnyWrite(t *testing.T) {
	for _, tc := range []struct {
		name, as, parent, raw, variable, notApplied string
		use, delegate, combined                     bool
		conflicts                                   int
		canAdd                                      bool
	}{
		{name: "delegated replacement", as: "replace", parent: "parent", variable: "TOKEN", use: true, conflicts: 1, canAdd: true},
		{name: "explicit addition preserves delegated base", as: "add", parent: "parent", variable: "TOKEN", use: true},
		{name: "person-owned replacement", as: "replace", variable: "TOKEN", use: true},
		{name: "combined delegation still conflicts", as: "replace", parent: "parent", variable: "TOKEN", use: true, delegate: true, combined: true, conflicts: 2, canAdd: true},
		{name: "delegation cannot become an addition", parent: "parent", variable: "TOKEN", delegate: true, combined: true, conflicts: 1},
		{name: "raw delivery has no addition shortcut", as: "replace", parent: "parent", raw: "env", variable: "TOKEN", use: true, conflicts: 1},
		{name: "another variable has no addition shortcut", as: "replace", parent: "parent", variable: "OTHER", use: true, conflicts: 1},
		{name: "inactive base has no addition shortcut", as: "replace", parent: "parent", variable: "TOKEN", notApplied: "expired", use: true, conflicts: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, _ := newBridge("http://fixture", false)
			b.allowManage = true
			writes := 0
			parent := tc.parent
			b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
				var value any
				switch r.URL.Path {
				case "/projects/p/secret-requests/ask":
					value = map[string]any{"id": "ask", "sandboxId": "requester", "envName": "TOKEN", "status": "pending", "use": map[string]any{}, "delegate": map[string]any{}}
				case "/projects/p/secrets":
					value = map[string]any{"secrets": []any{map[string]any{"id": "sec", "name": "Repository"}}}
				case "/projects/p/bound-secrets":
					value = map[string]any{"boundSecrets": []any{map[string]any{"bindingId": "existing", "secretId": "sec", "envVar": tc.variable, "use": true, "notApplied": tc.notApplied}}}
				case "/projects/p/secret-bindings":
					value = map[string]any{"secretBindings": []any{map[string]any{"id": "existing", "secretId": "sec", "targetKind": "sandbox", "targetId": "requester", "envVar": tc.variable,
						"use": true, "delegate": tc.combined, "parentId": parent, "raw": tc.raw, "createdAt": "2026-11-01T00:00:00Z"}}}
				case "/projects/p/secret-requests/ask/approve":
					if r.Method != http.MethodPost {
						t.Fatalf("unexpected mutation %s", r.Method)
					}
					writes++
					var body struct {
						Use      struct{ As, Scope, Raw string }
						Delegate struct{ Decision string }
					}
					if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
						t.Fatal(err)
					}
					if tc.use && (body.Use.As != tc.as || body.Use.Scope != "routes" || body.Use.Raw != "") {
						t.Fatalf("reviewed decision was altered: %+v", body)
					}
					value = map[string]any{"recorded": true}
				default:
					t.Fatalf("unexpected request %s %s", r.Method, r.URL)
				}
				if r.Method != http.MethodGet && !strings.HasSuffix(r.URL.Path, "/approve") {
					t.Fatalf("preview changed bindings: %s %s", r.Method, r.URL)
				}
				raw, _ := json.Marshal(value)
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(raw))), Header: make(http.Header)}, nil
			})
			use, delegate := map[string]any{"decision": "deny"}, map[string]any{"decision": "deny"}
			if tc.use {
				use = map[string]any{"decision": "approve", "as": tc.as, "scope": "routes"}
			}
			if tc.delegate {
				delegate = map[string]any{"decision": "approve", "scope": "routes"}
			}
			candidate, _ := json.Marshal(map[string]any{"secretId": "sec", "use": use, "delegate": delegate})
			req := request{Operation: "approvalContext", ProjectID: "p", RequestID: "ask", Payload: candidate}
			res, err := b.execute(t.Context(), req)
			if err != nil {
				t.Fatal(err)
			}
			var review approvalContext
			if err = json.Unmarshal(res.Body, &review); err != nil {
				t.Fatal(err)
			}
			if len(review.Conflicts) != tc.conflicts {
				t.Fatalf("conflicts = %+v", review.Conflicts)
			}
			for _, conflict := range review.Conflicts {
				if conflict.BindingID != "existing" || conflict.ParentID != tc.parent || conflict.CanAdd != (conflict.Part == "use" && tc.canAdd) {
					t.Fatalf("wrong conflict: %+v", conflict)
				}
			}
			if writes != 0 {
				t.Fatal("preview performed a write")
			}
			req.Operation, req.Kind, req.Action = "answer", "credential", "approve"
			req.Payload, _ = json.Marshal(map[string]any{"approval": json.RawMessage(candidate), "contextFingerprint": review.Fingerprint})
			_, err = b.execute(t.Context(), req)
			if tc.conflicts > 0 {
				if err == nil || writes != 0 {
					t.Fatalf("conflicting approval wrote: %d, %v", writes, err)
				}
			} else if err != nil || writes != 1 {
				t.Fatalf("reviewed approval writes = %d, err = %v", writes, err)
			}
			parent += "-changed"
			_, err = b.execute(t.Context(), req)
			if err == nil || !strings.Contains(err.Error(), "changed") {
				t.Fatalf("changed binding did not invalidate review: %v", err)
			}
			if tc.conflicts > 0 && writes != 0 || tc.conflicts == 0 && writes != 1 {
				t.Fatal("stale review wrote or repeated a mutation")
			}
		})
	}
}
