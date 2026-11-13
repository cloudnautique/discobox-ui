package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

// Editing shared restrictions is a separate explicit Settings operation. Never
// include values, bindings, routes, or rules in this bounded metadata update.
func (b *bridge) credentialLimits(ctx context.Context, req request) (response, error) {
	if !b.allowManage || validID(req.ProjectID) != nil || validID(req.RequestID) != nil {
		return response{}, errors.New("choose a credential on a connected computer before editing shared limits")
	}
	var input struct {
		Expected json.RawMessage            `json:"expectedSecret"`
		Limits   map[string]json.RawMessage `json:"limits"`
	}
	if json.Unmarshal(req.Payload, &input) != nil || len(input.Expected) == 0 || len(input.Limits) == 0 {
		return response{}, errors.New("invalid credential limit update")
	}
	path := "/projects/" + req.ProjectID + "/secrets/" + req.RequestID
	current, err := b.call(ctx, "GET", path, nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	if harnessReviewFingerprint(current.Body) != harnessReviewFingerprint(input.Expected) {
		return response{}, errors.New("this credential changed elsewhere; reopen its details before saving")
	}
	var metadata map[string]json.RawMessage
	if json.Unmarshal(current.Body, &metadata) != nil {
		return response{}, errors.New("invalid credential metadata")
	}
	field := "maxBindingTTLSeconds"
	if _, ok := metadata[field]; !ok {
		field = "maxGrantTTLSeconds"
	}
	if _, ok := metadata[field]; !ok {
		return response{}, errors.New("this server does not report editable credential lifetime limits")
	}
	for key, raw := range input.Limits {
		if key == "host" && field == "maxGrantTTLSeconds" {
			var host string
			if json.Unmarshal(raw, &host) != nil {
				return response{}, errors.New("invalid credential host")
			}
		} else if key == field {
			var seconds int64
			if json.Unmarshal(raw, &seconds) != nil || seconds < 0 {
				return response{}, errors.New("invalid credential lifetime")
			}
		} else {
			return response{}, errors.New("unsupported shared credential change")
		}
	}
	if _, ok := input.Limits[field]; !ok {
		return response{}, errors.New("missing credential lifetime")
	}
	body, _ := json.Marshal(input.Limits)
	result, err := b.call(ctx, "PATCH", path, body)
	if err != nil {
		return response{}, fmt.Errorf("shared limits may have changed; reload before retrying: %w", err)
	}
	return result, nil
}
