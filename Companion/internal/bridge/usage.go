package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/discobox-ai/discobox/pkg/auditid"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// Only recorded quota responses: never contacts a provider or executes a command.
func (b *Bridge) usage(ctx context.Context, req wire.Request) (wire.Response, error) {
	page := req.UsagePage
	if ValidID(req.ProjectID) != nil || ValidID(req.PoolID) != nil || page == nil || page.Limit < 1 || page.Limit > 100 ||
		(page.Host != "chatgpt.com" && page.Host != "api.anthropic.com") {
		return wire.Response{}, fmt.Errorf("invalid usage page scope")
	}
	query := url.Values{"poolId": {req.PoolID}, "host": {page.Host}, "order": {"desc"}, "limit": {strconv.Itoa(page.Limit)}}
	var through auditid.ExchangeID
	if page.After != "" {
		cursor, err := auditid.ParseExchange(page.After)
		if err != nil {
			return wire.Response{}, err
		}
		through = cursor
		query.Set("after", req.PoolID+":"+cursor.String())
		query.Set("order", "asc")
	}
	result, err := b.Call(ctx, http.MethodGet, "/api/projects/"+req.ProjectID+"/audit/http?"+query.Encode(), nil)
	if err != nil || result.Status != 200 {
		return result, err
	}
	var payload struct {
		Exchanges []struct {
			ID        auditid.ExchangeID `json:"id"`
			PoolID    string             `json:"poolId"`
			SandboxID string             `json:"sandboxId"`
			CreatedAt string             `json:"createdAt"`
			URL       string             `json:"url"`
			Status    int                `json:"status"`
			Recorded  *bool              `json:"responseBodyRecorded"`
		} `json:"exchanges"`
		UnavailablePools []json.RawMessage `json:"unavailablePools"`
	}
	if err := json.Unmarshal(result.Body, &payload); err != nil {
		return wire.Response{}, err
	}
	if payload.Exchanges == nil || len(payload.Exchanges) > page.Limit {
		return wire.Response{}, fmt.Errorf("invalid audit page")
	}
	if len(payload.UnavailablePools) > 0 {
		return wire.Response{Status: http.StatusServiceUnavailable, Body: json.RawMessage(`{"detail":"Pool audit unavailable."}`)}, nil
	}
	records := []map[string]string{}
	for _, row := range payload.Exchanges {
		if row.PoolID != req.PoolID || row.ID == 0 || (page.After != "" && row.ID <= through) {
			return wire.Response{}, fmt.Errorf("unusable audit cursor or pool")
		}
		through = max(through, row.ID)
		u, err := url.Parse(row.URL)
		if err != nil || u.Scheme != "https" || u.Hostname() != page.Host || row.Status != 200 {
			continue
		}
		provider := ""
		switch {
		case page.Host == "chatgpt.com" && u.Path == "/backend-api/wham/usage":
			provider = "codex"
		case page.Host == "api.anthropic.com" && u.Path == "/api/oauth/usage":
			provider = "claude"
		case page.Host == "api.anthropic.com" && u.Path == "/v1/messages":
			provider = "claude-headers"
		}
		if provider == "" || (provider != "claude-headers" && row.Recorded != nil && !*row.Recorded) {
			continue
		}
		if ValidID(row.SandboxID) != nil {
			return wire.Response{}, fmt.Errorf("missing usage recording identity")
		}
		records = append(records, map[string]string{"poolId": row.PoolID, "sandboxId": row.SandboxID, "id": row.ID.String(), "provider": provider, "createdAt": row.CreatedAt})
	}
	body, err := json.Marshal(map[string]any{"records": records, "through": through.String(), "full": len(payload.Exchanges) == page.Limit})
	return wire.Response{Version: wire.ProtocolVersion, Status: 200, Body: body}, err
}

// Return only quota headers, never message bodies or authentication headers.
func (b *Bridge) usageHeaders(ctx context.Context, req wire.Request) (wire.Response, error) {
	if ValidID(req.ProjectID) != nil || ValidID(req.PoolID) != nil || ValidID(req.RecordID) != nil || ValidID(req.SandboxID) != nil {
		return wire.Response{}, fmt.Errorf("invalid audit identity")
	}
	result, err := b.Call(ctx, "GET", "/api/projects/"+req.ProjectID+"/pools/"+req.PoolID+"/audit/http/"+req.RecordID+"?sandboxId="+url.QueryEscape(req.SandboxID), nil)
	if err != nil {
		return wire.Response{}, err
	}
	if result.Status != 200 {
		return result, nil
	}
	var detail struct {
		URL             string              `json:"url"`
		ResponseHeaders map[string][]string `json:"responseHeaders"`
	}
	if err = json.Unmarshal(result.Body, &detail); err != nil {
		return wire.Response{}, err
	}
	u, err := url.Parse(detail.URL)
	if err != nil || u.Scheme != "https" || u.Hostname() != "api.anthropic.com" || u.Path != "/v1/messages" {
		return wire.Response{}, fmt.Errorf("not an Anthropic message recording")
	}
	headers := map[string][]string{}
	for key, values := range detail.ResponseHeaders {
		key = strings.ToLower(key)
		switch key {
		case "anthropic-ratelimit-unified-5h-utilization", "anthropic-ratelimit-unified-7d-utilization", "anthropic-ratelimit-unified-5h-reset", "anthropic-ratelimit-unified-7d-reset":
			headers[key] = values
		}
	}
	body, err := json.Marshal(map[string]any{"headers": headers})
	return wire.Response{Version: wire.ProtocolVersion, Status: 200, Body: body}, err
}
