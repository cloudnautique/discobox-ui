package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestHarnessSaveIsAnExplicitReviewedCandidateOnItsOriginalBox(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	req := request{Operation: "saveHarnessChanges", ProjectID: "p", HarnessID: "h", SandboxID: "source"}
	if _, err := b.execute(t.Context(), req); err == nil {
		t.Fatal("unapproved save accepted")
	}
	b.allowManage = true
	state := "pending"
	candidate := "login-one"
	revision := 1
	assigned := "h"
	writes := 0
	lost := false
	preview := func() string {
		data, _ := json.Marshal(map[string]any{"candidateId": candidate, "harnessConfigId": "h", "configRevision": revision, "state": state, "files": []any{}, "credentials": []any{map[string]any{"provider": "claude-code", "type": "oauth", "envName": "TOKEN"}}})
		return string(data)
	}
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		var body string
		switch {
		case r.Method == "GET" && r.URL.Path == "/projects/p/sandboxes/source":
			body = `{"config":{"harnessConfigId":"` + assigned + `"}}`
		case r.Method == "GET" && r.URL.Path == "/api/projects/p/sandboxes/source/harness-config-changes":
			body = preview()
		case r.Method == "POST" && r.URL.Path == "/api/projects/p/sandboxes/source/harness-config-changes/save":
			writes++
			data, _ := io.ReadAll(r.Body)
			var fields map[string]any
			_ = json.Unmarshal(data, &fields)
			if len(fields) != 1 || fields["candidateId"] != "login-one" {
				t.Fatalf("unexpected save payload %s", data)
			}
			if lost {
				return nil, errors.New("reply lost")
			}
			body = `{"state":"saved-handoff-pending","candidateId":"login-one","harnessConfigId":"h"}`
		default:
			t.Fatalf("unexpected operation %s %s", r.Method, r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	req.Payload, _ = json.Marshal(map[string]string{"candidateId": candidate, "fingerprint": harnessReviewFingerprint([]byte(preview()))})
	revision++
	if _, err := b.execute(t.Context(), req); err == nil || writes != 0 {
		t.Fatal("shared-state change bypassed review")
	}
	revision--
	candidate = "login-two"
	if _, err := b.execute(t.Context(), req); err == nil || writes != 0 {
		t.Fatal("different login bypassed review")
	}
	candidate = "login-one"
	assigned = "other"
	if _, err := b.execute(t.Context(), req); err == nil || writes != 0 {
		t.Fatal("reassigned harness bypassed review")
	}
	assigned = "h"
	if result, err := b.execute(t.Context(), req); err != nil || writes != 1 || !strings.Contains(string(result.Body), "saved-handoff-pending") {
		t.Fatalf("save writes=%d err=%v", writes, err)
	}
	state = "saved-handoff-pending"
	req.Payload, _ = json.Marshal(map[string]string{"candidateId": candidate, "fingerprint": harnessReviewFingerprint([]byte(preview()))})
	if _, err := b.execute(t.Context(), req); err != nil || writes != 2 {
		t.Fatalf("handoff retry %d %v", writes, err)
	}
	lost = true
	if _, err := b.execute(t.Context(), req); err == nil || !strings.Contains(err.Error(), "may have succeeded") || writes != 3 {
		t.Fatalf("ambiguous save retried or hidden %d %v", writes, err)
	}
}

func TestHarnessDetailsLoadLegacyFieldsWithoutConsoleOrPrivateCapture(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Fatalf("read mutated %s", r.URL)
		}
		body := `{}`
		status := 200
		switch r.URL.Path {
		case "/projects/p/harness-configs/h":
			body = `{"id":"h","configured":true,"configCommand":["claude"],"futureField":true}`
		case "/projects/p/bound-secrets":
			if r.URL.Query().Get("target") != "h" || r.URL.Query().Get("targetKind") != "harnessConfig" {
				t.Fatal("wrong harness bindings")
			}
			status = 404
		case "/projects/p/secrets":
			body = `{"secrets":[{"id":"oauth","type":"oauth","name":"Login"}]}`
		default:
			t.Fatalf("private or unexpected route %s", r.URL)
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	result, err := b.execute(t.Context(), request{Operation: "harnessDetails", ProjectID: "p", HarnessID: "h"})
	if err != nil || result.Status != 200 || !strings.Contains(string(result.Body), `"configCommand"`) || !strings.Contains(string(result.Body), `"notice"`) {
		t.Fatalf("legacy config could not load %s %v", result.Body, err)
	}
}

func TestHarnessSaveBackHasTimeForTheServerHandoff(t *testing.T) {
	for _, operation := range []string{"harnessChanges", "saveHarnessChanges", "discardHarnessChanges"} {
		if requestTimeout(request{Operation: operation}) != 90*time.Second {
			t.Fatalf("handoff budget for %s is too short", operation)
		}
	}
	if requestTimeout(request{Operation: "harnessDetails"}) != 15*time.Second {
		t.Fatal("metadata reads were needlessly slowed")
	}
}
