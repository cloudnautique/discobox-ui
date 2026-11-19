package bridge

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"

	api "github.com/discobox-ai/discobox/api/gen"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// Only the audit data is a fixture. Discobox's pinned router matches the
// request, decodes its parameters, and serializes the response.
type usageAuditFixture struct {
	api.UnimplementedHandler
	t *testing.T
}

func (f usageAuditFixture) ListHTTPAudit(_ context.Context, p api.ListHTTPAuditParams) (api.ListHTTPAuditRes, error) {
	if p.ProjectId != "project" || p.PoolId.Or("") != "pool" || p.Limit.Or(0) != 64 {
		f.t.Errorf("unexpected audit scope: %+v", p)
	}
	row := api.HTTPAuditExchange{ID: "http_8", PoolId: "pool", SandboxId: "box", Status: http.StatusOK}
	switch p.Host.Or("") {
	case "chatgpt.com":
		if p.Order.Or("") != api.ListHTTPAuditOrderDesc || len(p.After) != 0 {
			f.t.Errorf("unexpected initial page: %+v", p)
		}
		row.URL = "https://chatgpt.com/backend-api/wham/usage"
	case "api.anthropic.com":
		if p.Order.Or("") != api.ListHTTPAuditOrderAsc || !slices.Equal(p.After, []string{"pool:http_7"}) {
			f.t.Errorf("unexpected incremental page: %+v", p)
		}
		row.URL = "https://api.anthropic.com/v1/messages"
	default:
		f.t.Errorf("unexpected host: %v", p.Host)
	}
	return &api.ListHTTPAuditBody{Exchanges: []api.HTTPAuditExchange{row}}, nil
}

func (f usageAuditFixture) GetHTTPAudit(_ context.Context, p api.GetHTTPAuditParams) (api.GetHTTPAuditRes, error) {
	if p.ProjectId != "project" || p.PoolId != "pool" || p.ExchangeId != "http_8" || p.SandboxId.Or("") != "box" {
		f.t.Errorf("unexpected recording identity: %+v", p)
	}
	return &api.HTTPAuditExchangeDetail{
		URL: "https://api.anthropic.com/v1/messages",
		ResponseHeaders: api.HTTPAuditExchangeDetailResponseHeaders{
			"Anthropic-Ratelimit-Unified-5h-Utilization": {"0.18"},
		},
	}, nil
}

func TestUsageAgainstDiscoboxRouter(t *testing.T) {
	router, err := api.NewServer(usageAuditFixture{t: t})
	if err != nil {
		t.Fatal(err)
	}
	b := Bridge{base: "http://discobox.local", client: &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, r)
		return recorder.Result(), nil
	})}}
	run := func(t *testing.T, req wire.Request, out any) {
		t.Helper()
		reply, err := b.execute(t.Context(), req)
		if err != nil || reply.Status != http.StatusOK {
			t.Fatalf("%s: HTTP %d, err %v, body %s", req.Operation, reply.Status, err, reply.Body)
		}
		if err := json.Unmarshal(reply.Body, out); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name, host, after, provider string
	}{
		{"initial page", "chatgpt.com", "", "codex"},
		{"incremental page", "api.anthropic.com", "http_7", "claude-headers"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var page struct {
				Records []struct{ ID, Provider string }
				Through string
			}
			run(t, wire.Request{
				Operation: "usage", ProjectID: "project", PoolID: "pool",
				UsagePage: &wire.UsagePage{Host: tc.host, After: tc.after, Limit: 64},
			}, &page)
			if len(page.Records) != 1 || page.Records[0].ID != "http_8" || page.Records[0].Provider != tc.provider || page.Through != "http_8" {
				t.Fatalf("unexpected usage page: %+v", page)
			}
		})
	}
	t.Run("Claude quota headers", func(t *testing.T) {
		var detail struct{ Headers map[string][]string }
		run(t, wire.Request{
			Operation: "usageHeaders", ProjectID: "project", PoolID: "pool", RecordID: "http_8", SandboxID: "box",
		}, &detail)
		if !slices.Equal(detail.Headers["anthropic-ratelimit-unified-5h-utilization"], []string{"0.18"}) {
			t.Fatalf("unexpected quota headers: %v", detail.Headers)
		}
	})
}
