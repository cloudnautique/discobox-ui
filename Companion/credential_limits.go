package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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
	result, err := b.call(ctx, "PUT", path, body)
	if err != nil {
		return response{}, fmt.Errorf("shared limits may have changed; reload before retrying: %w", err)
	}
	if result.Status < 200 || result.Status >= 300 {
		return result, nil
	}
	// A successful HTTP response is not proof of persistence (older routes can
	// even answer an unsupported method without updating the credential).
	// Read back once; never replay the write when verification fails.
	verified, err := b.call(ctx, "GET", path, nil)
	if err != nil || verified.Status != 200 {
		return response{}, errors.New("shared limits may have changed, but verification failed; reopen the credential details before retrying")
	}
	var saved map[string]json.RawMessage
	if json.Unmarshal(verified.Body, &saved) != nil {
		return response{}, errors.New("Discobox returned invalid credential metadata after saving; reopen the credential details before retrying")
	}
	var id string
	if json.Unmarshal(saved["id"], &id) != nil || id != req.RequestID {
		return response{}, errors.New("Discobox did not confirm the saved credential identity; reopen its details before retrying")
	}
	for key, expected := range input.Limits {
		if key == "host" {
			var want, got string
			if json.Unmarshal(expected, &want) != nil || (len(saved[key]) > 0 && json.Unmarshal(saved[key], &got) != nil) || strings.TrimSpace(strings.ToLower(want)) != strings.TrimSpace(strings.ToLower(got)) {
				return response{}, errors.New("Discobox did not retain the requested host restriction; reopen the credential details before retrying")
			}
		} else {
			var want, got int64
			if json.Unmarshal(expected, &want) != nil || json.Unmarshal(saved[key], &got) != nil || want != got {
				return response{}, errors.New("Discobox did not retain the requested lifetime limit; reopen the credential details before retrying")
			}
		}
	}
	return verified, nil
}
