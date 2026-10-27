package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

// Only recorded quota responses: never contacts a provider or executes a command.
func (b *bridge) usage(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil {
		return response{}, fmt.Errorf("invalid project")
	}
	records := []map[string]any{}
	missing := []string{}
	for _, host := range []string{"chatgpt.com", "api.anthropic.com"} {
		query := url.Values{"host": {host}, "order": {"desc"}, "limit": {"200"}}
		result, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/audit/http?"+query.Encode(), nil)
		if err != nil || result.Status != 200 {
			missing = append(missing, host+": audit unavailable")
			continue
		}
		var payload struct {
			Exchanges        []map[string]any  `json:"exchanges"`
			UnavailablePools []json.RawMessage `json:"unavailablePools"`
		}
		if json.Unmarshal(result.Body, &payload) != nil {
			missing = append(missing, host+": invalid audit response")
			continue
		}
		if len(payload.UnavailablePools) > 0 {
			missing = append(missing, host+": some pools unavailable")
		}
		if len(payload.Exchanges) >= 200 {
			missing = append(missing, host+": searched latest 200 requests")
		}
		for _, row := range payload.Exchanges {
			raw, _ := row["url"].(string)
			u, err := url.Parse(raw)
			if err != nil || u.Scheme != "https" || u.Hostname() != host {
				continue
			}
			provider := ""
			if host == "chatgpt.com" && u.Path == "/backend-api/wham/usage" {
				provider = "codex"
			}
			if host == "api.anthropic.com" && u.Path == "/api/oauth/usage" {
				provider = "claude"
			}
			if host == "api.anthropic.com" && u.Path == "/v1/messages" {
				provider = "claude-headers"
			}
			if provider == "" || row["status"] != float64(200) || row["responseBodyRecorded"] == false {
				continue
			}
			records = append(records, map[string]any{"id": row["id"], "poolId": row["poolId"], "sandboxId": row["sandboxId"], "createdAt": row["createdAt"], "provider": provider})
		}
	}
	body, err := json.Marshal(map[string]any{"records": records, "missing": missing})
	return response{Version: 1, Status: 200, Body: body}, err
}

// Return only quota headers, never message bodies or authentication headers.
func (b *bridge) usageHeaders(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.Kind) != nil || validID(req.RequestID) != nil || validID(req.SandboxID) != nil {
		return response{}, fmt.Errorf("invalid audit identity")
	}
	result, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/pools/"+req.Kind+"/audit/http/"+req.RequestID+"?sandboxId="+url.QueryEscape(req.SandboxID), nil)
	if err != nil {
		return response{}, err
	}
	if result.Status != 200 {
		return result, nil
	}
	var detail struct {
		URL             string              `json:"url"`
		ResponseHeaders map[string][]string `json:"responseHeaders"`
	}
	if err = json.Unmarshal(result.Body, &detail); err != nil {
		return response{}, err
	}
	u, err := url.Parse(detail.URL)
	if err != nil || u.Scheme != "https" || u.Hostname() != "api.anthropic.com" || u.Path != "/v1/messages" {
		return response{}, fmt.Errorf("not an Anthropic message recording")
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
	return response{Version: 1, Status: 200, Body: body}, err
}
