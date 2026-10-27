package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

func TestUsageOnlyReadsBoundedAuditAndReturnsQuotaCandidates(t *testing.T) {
	calls := 0
	b := &bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || r.URL.Path != "/projects/p/audit/http" || r.URL.Query().Get("limit") != "200" {
			t.Fatalf("unexpected request %s", r.URL)
		}
		if r.URL.Query().Get("host") == "api.anthropic.com" {
			return reply(`{"exchanges":[]}`), nil
		}
		return reply(`{"exchanges":[
   {"id":"http_1","poolId":"pool","sandboxId":"box","createdAt":"2026-10-27T17:00:00Z","url":"https://chatgpt.com/backend-api/wham/usage","status":200,"requestHeaders":{"Authorization":"never forward"}},
   {"id":"http_2","url":"https://evil.example/backend-api/wham/usage","status":200,"responseBodyRecorded":true},
   {"id":"http_3","url":"https://chatgpt.com/backend-api/wham/usage","status":403,"responseBodyRecorded":true},
   {"id":"http_4","url":"https://chatgpt.com/backend-api/wham/usage","status":200,"responseBodyRecorded":false}
  ]}`), nil
	})}}
	result, err := b.usage(context.Background(), request{ProjectID: "p"})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Records []map[string]any `json:"records"`
	}
	if err = json.Unmarshal(result.Body, &out); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || len(out.Records) != 1 || out.Records[0]["provider"] != "codex" {
		t.Fatalf("unexpected result %s", result.Body)
	}
	if _, ok := out.Records[0]["requestHeaders"]; ok {
		t.Fatal("leaked request headers")
	}
}

func TestUsageHeadersOnlyReturnsSubscriptionQuotaFields(t *testing.T) {
	b := &bridge{base: "http://fixture", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" || r.URL.Path != "/projects/p/pools/pool/audit/http/http_1" || r.URL.Query().Get("sandboxId") != "box" {
			t.Fatalf("unexpected request %s", r.URL)
		}
		return reply(`{"url":"https://api.anthropic.com/v1/messages?beta=true","responseHeaders":{"Anthropic-Ratelimit-Unified-5h-Utilization":["0.1"],"Anthropic-Ratelimit-Unified-7d-Utilization":["0.03"],"Set-Cookie":["private"],"anthropic-ratelimit-requests-remaining":["99"]},"requestHeaders":{"Authorization":"private"}}`), nil
	})}}
	result, err := b.usageHeaders(context.Background(), request{ProjectID: "p", Kind: "pool", RequestID: "http_1", SandboxID: "box"})
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
