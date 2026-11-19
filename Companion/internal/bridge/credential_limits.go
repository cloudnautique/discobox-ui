package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// Editing shared restrictions is a separate explicit Settings operation. Never
// include token values, bindings or harness-owned constraints in the update.
func (b *Bridge) credentialLimits(ctx context.Context, req wire.Request) (wire.Response, error) {
	if ValidID(req.ProjectID) != nil || ValidID(req.SecretID) != nil {
		return wire.Response{}, errors.New("choose a credential on a connected computer before editing shared limits")
	}
	var input struct {
		Expected json.RawMessage            `json:"expectedSecret"`
		Limits   map[string]json.RawMessage `json:"limits"`
	}
	if json.Unmarshal(req.Payload, &input) != nil || len(input.Expected) == 0 || len(input.Limits) == 0 {
		return wire.Response{}, errors.New("invalid credential limit update")
	}
	path := "/projects/" + req.ProjectID + "/secrets/" + req.SecretID
	current, err := b.Call(ctx, "GET", path, nil)
	if err != nil || current.Status != 200 {
		return current, err
	}
	if harnessReviewFingerprint(current.Body) != harnessReviewFingerprint(input.Expected) {
		return wire.Response{}, errors.New("this credential changed elsewhere; reopen its details before saving")
	}
	var metadata map[string]json.RawMessage
	if json.Unmarshal(current.Body, &metadata) != nil {
		return wire.Response{}, errors.New("invalid credential metadata")
	}
	field := "maxBindingTTLSeconds"
	if _, ok := metadata[field]; !ok {
		field = "maxGrantTTLSeconds"
	}
	if _, ok := metadata[field]; !ok {
		return wire.Response{}, errors.New("this server does not report editable credential lifetime limits")
	}
	var requestedRoutes credentialRouteList
	for key, raw := range input.Limits {
		if key == "routes" && field == "maxBindingTTLSeconds" {
			requestedRoutes, err = credentialRoutes(raw, false)
			if err != nil {
				return wire.Response{}, err
			}
			input.Limits[key], err = json.Marshal(requestedRoutes.Routes)
			if err != nil {
				return wire.Response{}, err
			}
		} else if key == "host" && field == "maxGrantTTLSeconds" {
			var host string
			if json.Unmarshal(raw, &host) != nil {
				return wire.Response{}, errors.New("invalid credential host")
			}
		} else if key == field {
			var seconds int64
			if json.Unmarshal(raw, &seconds) != nil || seconds < 0 {
				return wire.Response{}, errors.New("invalid credential lifetime")
			}
		} else {
			return wire.Response{}, errors.New("unsupported shared credential change")
		}
	}
	if _, ok := input.Limits[field]; !ok && input.Limits["routes"] == nil {
		return wire.Response{}, errors.New("missing credential lifetime")
	}
	body, _ := json.Marshal(input.Limits)
	result, err := b.Call(ctx, "PUT", path, body)
	if err != nil {
		return wire.Response{}, fmt.Errorf("shared limits may have changed; reload before retrying: %w", err)
	}
	if result.Status < 200 || result.Status >= 300 {
		return result, nil
	}
	// A successful HTTP response is not proof of persistence (older routes can
	// even answer an unsupported method without updating the credential).
	// Read back once; never replay the write when verification fails.
	verified, err := b.Call(ctx, "GET", path, nil)
	if err != nil || verified.Status != 200 {
		return wire.Response{}, errors.New("shared limits may have changed, but verification failed; reopen the credential details before retrying")
	}
	var saved map[string]json.RawMessage
	if json.Unmarshal(verified.Body, &saved) != nil {
		return wire.Response{}, errors.New("Discobox returned invalid credential metadata after saving; reopen the credential details before retrying")
	}
	var id string
	if json.Unmarshal(saved["id"], &id) != nil || id != req.SecretID {
		return wire.Response{}, errors.New("Discobox did not confirm the saved credential identity; reopen its details before retrying")
	}
	for key, expected := range input.Limits {
		if key == "routes" {
			raw := saved[key]
			// An empty route list is omitted by Discobox's secret summary.
			if len(raw) == 0 || string(raw) == "null" {
				raw = json.RawMessage("[]")
			}
			got, err := credentialRoutes(raw, false)
			if err != nil || !slices.Equal(requestedRoutes.Lines, got.Lines) {
				return wire.Response{}, errors.New("Discobox did not confirm the saved routes; reopen the credential details before retrying")
			}
		} else if key == "host" {
			var want, got string
			if json.Unmarshal(expected, &want) != nil || (len(saved[key]) > 0 && json.Unmarshal(saved[key], &got) != nil) || strings.TrimSpace(strings.ToLower(want)) != strings.TrimSpace(strings.ToLower(got)) {
				return wire.Response{}, errors.New("Discobox did not retain the requested host restriction; reopen the credential details before retrying")
			}
		} else {
			var want, got int64
			if json.Unmarshal(expected, &want) != nil || json.Unmarshal(saved[key], &got) != nil || want != got {
				return wire.Response{}, errors.New("Discobox did not retain the requested lifetime limit; reopen the credential details before retrying")
			}
		}
	}
	return verified, nil
}
