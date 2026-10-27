package main

import (
	"context"
	"encoding/json"
	"errors"
)

func (b *bridge) approvals(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil {
		return response{}, errors.New("invalid project")
	}
	base := "/projects/" + req.ProjectID
	switch req.Operation {
	case "approvals":
		return b.call(ctx, "GET", base+"/approval-requests?status=pending", nil)
	case "secrets":
		return b.call(ctx, "GET", base+"/secrets", nil)
	case "ruleProposals":
		if validID(req.RequestID) != nil {
			return response{}, errors.New("invalid request")
		}
		return b.call(ctx, "POST", base+"/secret-requests/"+req.RequestID+"/rule-proposals", nil)
	}
	if !b.allowManage {
		return response{}, errors.New("answering requests requires explicit permission")
	}
	if req.Operation == "createSecret" {
		return b.call(ctx, "POST", base+"/secrets", req.Payload)
	}
	if validID(req.RequestID) != nil {
		return response{}, errors.New("invalid request")
	}
	resource := "secret-requests"
	if req.Kind == "trust" {
		resource = "trust-requests"
	} else if req.Kind != "credential" {
		return response{}, errors.New("unknown request kind")
	}
	path := base + "/" + resource + "/" + req.RequestID
	// Re-read the specific request: never answer a request that polling has
	// removed, and never replay a failed POST whose outcome may be ambiguous.
	current, err := b.call(ctx, "GET", path, nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	var item map[string]json.RawMessage
	if err := json.Unmarshal(current.Body, &item); err != nil {
		return response{}, err
	}
	var status string
	_ = json.Unmarshal(item["status"], &status)
	if status != "pending" {
		return response{}, errors.New("this request has already been answered; refresh the inbox")
	}
	switch req.Action {
	case "approve", "deny":
		return b.call(ctx, "POST", path+"/"+req.Action, req.Payload)
	case "refresh":
		var secret, reason string
		_ = json.Unmarshal(item["secretId"], &secret)
		_ = json.Unmarshal(item["reason"], &reason)
		if reason != "refresh" || validID(secret) != nil {
			return response{}, errors.New("not a refresh request")
		}
		var body map[string]json.RawMessage
		if err := json.Unmarshal(req.Payload, &body); err != nil {
			return response{}, err
		}
		body["requestId"], _ = json.Marshal(req.RequestID)
		payload, _ := json.Marshal(body)
		return b.call(ctx, "POST", base+"/secrets/"+secret+"/refresh", payload)
	default:
		return response{}, errors.New("unknown approval action")
	}
}
