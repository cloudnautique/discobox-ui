package main

import (
	"context"
	"encoding/json"
	api "github.com/discobox-ai/discobox/api/gen"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCloseShellCannotEndAgentAndNeedsExplicitPermission(t *testing.T) {
	for _, record := range []string{`{"primary":true,"tty":true}`, `{"tty":true,"harnessId":"agent"}`, `{"tty":true,"observedAt":"saved"}`, `{"tty":false}`} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		deletes := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			if r.Method == "DELETE" {
				deletes++
			}
			return reply(record), nil
		})
		_, err := b.execute(t.Context(), request{Operation: "closeShell", ProjectID: "p", SandboxID: "b", ExecID: "e"})
		if err == nil || deletes != 0 {
			t.Fatalf("unsafe close %s %v", record, err)
		}
	}
	b, _ := newBridge("http://fixture", false)
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) { t.Fatal("unauthorized transport"); return nil, nil })
	for _, op := range []string{"createBox", "closeShell"} {
		if _, err := b.execute(t.Context(), request{Operation: op, ProjectID: "p", SandboxID: "b", ExecID: "e"}); err == nil {
			t.Fatal(op)
		}
	}
}

func TestCloseShellDeletesOnlySelectedShell(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	var calls []string
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		return reply(`{"tty":true,"primary":false}`), nil
	})
	_, err := b.execute(t.Context(), request{Operation: "closeShell", ProjectID: "p", SandboxID: "b", ExecID: "shell"})
	if err != nil || strings.Join(calls, "|") != "GET /api/projects/p/sandboxes/b/execs/shell|DELETE /api/projects/p/sandboxes/b/execs/shell" {
		t.Fatalf("%v %v", calls, err)
	}
}

func TestAuditIncludesFiveTrailsAndReportsMissingPools(t *testing.T) {
	b, _ := newBridge("http://fixture", false)
	var mu sync.Mutex
	seen := map[string]bool{}
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			t.Error("audit mutated server")
		}
		mu.Lock()
		seen[r.URL.Path] = true
		mu.Unlock()
		switch {
		case strings.HasSuffix(r.URL.Path, "/audit/http"):
			if r.URL.Query().Get("sandboxId") != "b" {
				t.Error("missing box filter")
			}
			return reply(`{"exchanges":[{"id":"http_1","poolId":"pool-a","createdAt":"2026-10-26T14:00:00Z","method":"GET","status":200,"url":"https://example.test"},{"id":"http_1","poolId":"pool-b","createdAt":"2026-10-26T14:00:01Z","method":"GET","status":403}],"unavailablePools":[{"poolId":"offline","reason":"not answering"}]}`), nil
		case strings.HasSuffix(r.URL.Path, "/credential-verdicts"):
			return reply(`{"credentialVerdicts":[]}`), nil
		case strings.HasSuffix(r.URL.Path, "/secret-refreshes"):
			return reply(`{"secretRefreshEvents":[]}`), nil
		case strings.HasSuffix(r.URL.Path, "/harness-hooks"):
			return reply(`{"hooks":[{"id":"h","createdAt":"2026-10-26T14:00:02Z","event":"start"}]}`), nil
		default:
			res := reply(`{}`)
			res.StatusCode = 503
			return res, nil
		}
	})
	result, err := b.audit(t.Context(), request{ProjectID: "p", SandboxID: "b"})
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Records []auditRow
		Missing []string
	}
	if err := json.Unmarshal(result.Body, &data); err != nil {
		t.Fatal(err)
	}
	if len(seen) != 5 || len(data.Records) != 3 || len(data.Missing) != 2 || data.Records[1].ID == data.Records[2].ID {
		t.Fatalf("%+v %+v", seen, data)
	}
}

func TestCreateBoxWithoutRepositoryUsesSelectedHarness(t *testing.T) {
	t.Setenv("DISCOBOX_HOST_ID", "fixture-host")
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	creates := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/harness-configs/h") {
			return reply(`{"id":"h","name":"Claude Code","slug":"claude-code","configured":true}`), nil
		}
		if r.Method == "GET" && r.URL.Path == "/projects/p" {
			return reply(`{}`), nil
		}
		if r.Method != "POST" || r.URL.Path != "/projects/p/sandboxes" {
			t.Fatalf("unexpected operation %s %s", r.Method, r.URL)
		}
		creates++
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["harnessName"] != nil {
			t.Fatalf("an exact ID must not be sent as a name: %v", body)
		}
		config := body["config"].(map[string]any)
		if config["harnessConfigId"] != "h" {
			t.Fatalf("wrong harness identity: %v", config)
		}
		if prompt, ok := config["prompt"].([]any); !ok || len(prompt) != 1 || prompt[0] != "first line\nsecond line" {
			t.Fatalf("prompt changed: %v", config)
		}
		if config["source"] != nil {
			t.Fatal("unexpected repository")
		}
		box := api.Sandbox{ID: "new-box", ProjectId: "p", DisplayName: "New box", CreatedAt: time.Now(), UpdatedAt: time.Now(), Runtime: api.SandboxRuntime{State: api.SandboxRuntimeStateReady, DesiredState: api.SandboxRuntimeDesiredStatePresent}}
		encoded, err := json.Marshal(&box)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: 202, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(encoded)))}, nil
	})
	result, err := b.createBox(context.Background(), request{ProjectID: "p", HarnessID: "h", Prompt: "first line\nsecond line"})
	if err != nil {
		t.Fatal(err)
	}
	if creates != 1 || !strings.Contains(string(result.Body), "new-box") {
		t.Fatalf("unexpected result %s", result.Body)
	}
}

func TestCreateBoxReturnsReadableProblemWithoutRetry(t *testing.T) {
	t.Setenv("DISCOBOX_HOST_ID", "fixture-host")
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	creates := 0
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/harness-configs/h") {
			return reply(`{"id":"h","slug":"claude-code","configured":true}`), nil
		}
		if r.Method == "GET" && r.URL.Path == "/projects/p" {
			return reply(`{}`), nil
		}
		if r.Method != "POST" || r.URL.Path != "/projects/p/sandboxes" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL)
		}
		creates++
		return &http.Response{StatusCode: 404, Header: http.Header{"Content-Type": []string{"application/problem+json"}}, Body: io.NopCloser(strings.NewReader(`{"status":404,"title":"Not Found","detail":"harness config not found","type":"about:blank"}`))}, nil
	})
	result, err := b.createBox(t.Context(), request{ProjectID: "p", HarnessID: "h"})
	if err != nil {
		t.Fatal(err)
	}
	var problem struct {
		Detail string `json:"detail"`
	}
	if json.Unmarshal(result.Body, &problem) != nil || result.Status != 404 || problem.Detail != "harness config not found" || creates != 1 {
		t.Fatalf("bad error response: %+v, creates=%d", result, creates)
	}
}
