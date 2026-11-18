package bridge

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func TestUsageOnlyReadsBoundedAuditAndReturnsQuotaCandidates(t *testing.T) {
	calls := 0
	b := &Bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || r.URL.Path != "/api/projects/p/audit/http" || r.URL.Query().Get("limit") != "64" || r.URL.Query().Get("poolId") != "pool" {
			t.Fatalf("unexpected request %s", r.URL)
		}
		if r.URL.Query().Get("host") == "api.anthropic.com" {
			return reply(`{"exchanges":[]}`), nil
		}
		return reply(`{"exchanges":[
   {"id":"http_1","poolId":"pool","sandboxId":"box","createdAt":"2026-10-27T17:00:00Z","url":"https://chatgpt.com/backend-api/wham/usage","status":200,"requestHeaders":{"Authorization":"never forward"}},
   {"id":"http_2","poolId":"pool","url":"https://evil.example/backend-api/wham/usage","status":200,"responseBodyRecorded":true},
   {"id":"http_3","poolId":"pool","url":"https://chatgpt.com/backend-api/wham/usage","status":403,"responseBodyRecorded":true},
   {"id":"http_4","poolId":"pool","url":"https://chatgpt.com/backend-api/wham/usage","status":200,"responseBodyRecorded":false}
  ]}`), nil
	})}}
	result, err := b.usage(context.Background(), wire.Request{ProjectID: "p", PoolID: "pool", UsagePage: &wire.UsagePage{Host: "chatgpt.com", Limit: 64}})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Through string           `json:"through"`
		Records []map[string]any `json:"records"`
	}
	if err = json.Unmarshal(result.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Through != "http_4" || calls != 1 || len(out.Records) != 1 || out.Records[0]["provider"] != "codex" {
		t.Fatalf("unexpected result %s", result.Body)
	}
	if _, ok := out.Records[0]["requestHeaders"]; ok {
		t.Fatal("leaked request headers")
	}
}

func TestUsageHeadersOnlyReturnsSubscriptionQuotaFields(t *testing.T) {
	b := &Bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" || r.URL.Path != "/api/projects/p/pools/pool/audit/http/http_1" || r.URL.Query().Get("sandboxId") != "box" {
			t.Fatalf("unexpected request %s", r.URL)
		}
		return reply(`{"url":"https://api.anthropic.com/v1/messages?beta=true","responseHeaders":{"Anthropic-Ratelimit-Unified-5h-Utilization":["0.1"],"Anthropic-Ratelimit-Unified-7d-Utilization":["0.03"],"Set-Cookie":["private"],"anthropic-ratelimit-requests-remaining":["99"]},"requestHeaders":{"Authorization":"private"}}`), nil
	})}}
	result, err := b.usageHeaders(context.Background(), wire.Request{ProjectID: "p", PoolID: "pool", RecordID: "http_1", SandboxID: "box"})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Headers map[string][]string `json:"headers"`
	}
	if err = json.Unmarshal(result.Body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Headers) != 2 || out.Headers["anthropic-ratelimit-unified-5h-utilization"][0] != "0.1" {
		t.Fatalf("unexpected quota headers: %s", result.Body)
	}
}

func TestUsageAdvancesAcrossRejectedRowsInPoolWriteOrder(t *testing.T) {
	b := &Bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		if q.Get("after") != "a:http_7" || q.Get("poolId") != "a" || q.Get("order") != "asc" || q.Get("host") != "api.anthropic.com" {
			t.Fatal(q)
		}
		return reply(`{"exchanges":[
		{"id":"http_8","poolId":"a","sandboxId":"x","createdAt":"2025-04-02","url":"https://api.anthropic.com/v1/models","status":200},
		{"id":"http_9","poolId":"a","sandboxId":"x","createdAt":"2025-04-01","url":"https://api.anthropic.com/v1/messages","status":200,"responseBodyRecorded":false}
		]}`), nil
	})}}
	result, err := b.usage(context.Background(), wire.Request{ProjectID: "p", PoolID: "a", UsagePage: &wire.UsagePage{Host: "api.anthropic.com", Limit: 2, After: "http_7"}})
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Through string
		Full    bool
		Records []struct{ Provider string }
	}
	if err := json.Unmarshal(result.Body, &data); err != nil || data.Through != "http_9" || !data.Full || len(data.Records) != 1 || data.Records[0].Provider != "claude-headers" {
		t.Fatal(string(result.Body), err)
	}
}
