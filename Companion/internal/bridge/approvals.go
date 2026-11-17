package bridge

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func (b *Bridge) approvals(ctx context.Context, req wire.Request) (wire.Response, error) {
	if ValidID(req.ProjectID) != nil {
		return wire.Response{}, errors.New("invalid project")
	}
	base := "/projects/" + req.ProjectID
	switch req.Operation {
	case "approvals":
		return b.Call(ctx, "GET", base+"/approval-requests?status=pending", nil)
	case "secrets":
		return b.Call(ctx, "GET", base+"/secrets", nil)
	case "approvalContext":
		return b.previewCredential(ctx, req)
	}
	if req.Operation == "deleteSecret" {
		if ValidID(req.SecretID) != nil {
			return wire.Response{}, errors.New("invalid credential")
		}
		return b.Call(ctx, "DELETE", base+"/secrets/"+req.SecretID, nil)
	}
	if req.Operation == "createSecret" {
		return b.Call(ctx, "POST", base+"/secrets", req.Payload)
	}
	if ValidID(req.RequestID) != nil {
		return wire.Response{}, errors.New("invalid request")
	}
	var resource string
	switch req.Kind {
	case "credential":
		resource = "secret-requests"
	case "trust":
		resource = "trust-requests"
	case "apiAccess":
		resource = "api-access-requests"
	case "adoption":
		resource = "adoption-requests"
	case "refresh":
		return b.refreshApproval(ctx, base, req)
	default:
		return wire.Response{}, errors.New("unknown request kind")
	}
	path := base + "/" + resource + "/" + req.RequestID
	// Re-read the specific request: never answer a request that polling has
	// removed, and never replay a failed POST whose outcome may be ambiguous.
	current, err := b.Call(ctx, "GET", path, nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	var item map[string]json.RawMessage
	if err := json.Unmarshal(current.Body, &item); err != nil {
		return wire.Response{}, err
	}
	var status string
	_ = json.Unmarshal(item["status"], &status)
	if status != "pending" {
		return wire.Response{}, errors.New("this request has already been answered; refresh the inbox")
	}
	if req.Kind == "apiAccess" || req.Kind == "adoption" {
		if req.Action != "approve" && req.Action != "deny" {
			return wire.Response{}, errors.New("invalid consent action")
		}
		return b.Call(ctx, "POST", path+"/"+req.Action, nil)
	}
	if req.Kind == "credential" && req.Action == "approve" && ((len(item["use"]) > 0 && string(item["use"]) != "null") || (len(item["delegate"]) > 0 && string(item["delegate"]) != "null")) {
		payload, res, err := b.reviewedCredential(ctx, req)
		if err != nil || res.Status != 0 {
			return res, err
		}
		return b.Call(ctx, "POST", path+"/approve", payload)
	}
	switch req.Action {
	case "approve", "deny":
		return b.Call(ctx, "POST", path+"/"+req.Action, req.Payload)
	case "refresh":
		var secret, reason string
		_ = json.Unmarshal(item["secretId"], &secret)
		_ = json.Unmarshal(item["reason"], &reason)
		if reason != "refresh" || ValidID(secret) != nil {
			return wire.Response{}, errors.New("not a refresh request")
		}
		var body map[string]json.RawMessage
		if err := json.Unmarshal(req.Payload, &body); err != nil {
			return wire.Response{}, err
		}
		body["requestId"], _ = json.Marshal(req.RequestID)
		payload, _ := json.Marshal(body)
		return b.Call(ctx, "POST", base+"/secrets/"+secret+"/refresh", payload)
	default:
		return wire.Response{}, errors.New("unknown approval action")
	}
}

// Refresh requests have list/dismiss routes, not a GET-by-ID route. Re-read
// the pending list immediately before writing the shared credential value.
func (b *Bridge) refreshApproval(ctx context.Context, base string, req wire.Request) (wire.Response, error) {
	if req.Action != "refresh" && req.Action != "deny" {
		return wire.Response{}, errors.New("invalid refresh action")
	}
	current, err := b.Call(ctx, "GET", base+"/secret-refresh-requests?status=pending", nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	var list struct {
		Requests []struct {
			ID     string `json:"id"`
			Secret string `json:"secretId"`
			Status string `json:"status"`
		} `json:"secretRefreshRequests"`
	}
	if err := json.Unmarshal(current.Body, &list); err != nil {
		return wire.Response{}, err
	}
	for _, item := range list.Requests {
		if item.ID != req.RequestID || item.Status != "pending" {
			continue
		}
		if req.Action == "deny" {
			return b.Call(ctx, "POST", base+"/secret-refresh-requests/"+req.RequestID+"/dismiss", nil)
		}
		if ValidID(item.Secret) != nil {
			return wire.Response{}, errors.New("invalid refresh credential")
		}
		var body map[string]json.RawMessage
		if err := json.Unmarshal(req.Payload, &body); err != nil {
			return wire.Response{}, err
		}
		var value string
		if err := json.Unmarshal(body["value"], &value); err != nil || value == "" {
			return wire.Response{}, errors.New("enter a replacement token")
		}
		// Only manual values are accepted by this operation. Suggested commands
		// are displayed to the person, never executed implicitly.
		payload, _ := json.Marshal(map[string]any{"value": value, "via": "entered", "requestId": req.RequestID})
		return b.Call(ctx, "POST", base+"/secrets/"+item.Secret+"/refresh", payload)
	}
	return wire.Response{}, errors.New("this refresh request has already been answered; refresh the inbox")
}
