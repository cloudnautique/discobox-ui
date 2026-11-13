package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
)

func harnessReviewFingerprint(raw []byte) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return ""
	}
	data, _ := json.Marshal(value)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// Only public metadata and the server's redacted preview cross this bridge.
// Private capture/acknowledgment and exported credential values stay upstream.
func (b *bridge) harnessManagement(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.HarnessID) != nil {
		return response{}, errors.New("invalid harness destination")
	}
	base := "/projects/" + req.ProjectID
	if req.Operation == "harnessDetails" {
		config, err := b.call(ctx, "GET", base+"/harness-configs/"+req.HarnessID, nil)
		if err != nil || config.Status != 200 {
			return config, err
		}
		bindings, err := b.call(ctx, "GET", base+"/bound-secrets?targetKind=harnessConfig&target="+url.QueryEscape(req.HarnessID), nil)
		if err != nil {
			return bindings, err
		}
		var held struct {
			Bound []json.RawMessage `json:"boundSecrets"`
		}
		var note string
		if bindings.Status == 404 {
			note = "This server does not report resolved harness bindings."
		} else if bindings.Status != 200 {
			return bindings, nil
		} else if err = json.Unmarshal(bindings.Body, &held); err != nil {
			return response{}, err
		}
		secrets, err := b.call(ctx, "GET", base+"/secrets", nil)
		if err != nil || secrets.Status != 200 {
			return secrets, err
		}
		var metadata struct {
			Secrets []json.RawMessage `json:"secrets"`
		}
		if err = json.Unmarshal(secrets.Body, &metadata); err != nil {
			return response{}, err
		}
		body, err := json.Marshal(map[string]any{"harness": json.RawMessage(config.Body), "bindings": held.Bound, "secrets": metadata.Secrets, "notice": note})
		return response{Status: 200, Body: body}, err
	}
	if validID(req.SandboxID) != nil {
		return response{}, errors.New("choose a running box to review its harness changes")
	}
	mutating := req.Operation == "saveHarnessChanges" || req.Operation == "discardHarnessChanges"
	if mutating && !b.allowManage {
		return response{}, errors.New("saving harness changes requires explicit permission")
	}
	box, err := b.call(ctx, "GET", base+"/sandboxes/"+req.SandboxID, nil)
	if err != nil || box.Status != 200 {
		return box, err
	}
	var owner struct {
		Config struct {
			Harness string `json:"harnessConfigId"`
		} `json:"config"`
	}
	if json.Unmarshal(box.Body, &owner) != nil || owner.Config.Harness != req.HarnessID {
		return response{}, errors.New("this box's harness changed; choose a box again")
	}
	path := "/api" + base + "/sandboxes/" + req.SandboxID + "/harness-config-changes"
	current, err := b.call(ctx, "GET", path, nil)
	if err != nil {
		return current, err
	}
	if current.Status == 404 {
		if !mutating {
			body, _ := json.Marshal(map[string]any{"changes": map[string]any{"state": "unsupported", "files": []any{}, "credentials": []any{}}, "fingerprint": harnessReviewFingerprint(current.Body)})
			return response{Status: 200, Body: body}, nil
		}
		current.Body = []byte(`{"detail":"This server or box image does not support saving harness changes. Update the server and harness image."}`)
	}
	if current.Status != 200 {
		return current, nil
	}
	var preview struct {
		Candidate          string `json:"candidateId"`
		Harness            string `json:"harnessConfigId"`
		State              string `json:"state"`
		Files, Credentials []json.RawMessage
	}
	if json.Unmarshal(current.Body, &preview) != nil {
		return response{}, errors.New("invalid harness change preview")
	}
	transient := preview.State == "unsupported" || preview.State == "initializing" || preview.State == "unavailable"
	if preview.Harness != req.HarnessID && !(preview.Harness == "" && transient && preview.Candidate == "" && len(preview.Files)+len(preview.Credentials) == 0) {
		return response{}, errors.New("invalid harness change preview")
	}
	fingerprint := harnessReviewFingerprint(current.Body)
	if req.Operation == "harnessChanges" {
		body, err := json.Marshal(map[string]any{"changes": json.RawMessage(current.Body), "fingerprint": fingerprint})
		return response{Status: 200, Body: body}, err
	}
	var input struct {
		Candidate   string `json:"candidateId"`
		Fingerprint string `json:"fingerprint"`
	}
	if json.Unmarshal(req.Payload, &input) != nil || input.Candidate == "" || input.Candidate != preview.Candidate || input.Fingerprint == "" || input.Fingerprint != fingerprint {
		return response{}, errors.New("the harness changes or shared configuration changed; review the current preview before saving")
	}
	action := ""
	switch req.Operation {
	case "saveHarnessChanges":
		if !(preview.State == "saved-handoff-pending" || preview.State == "pending" && len(preview.Files)+len(preview.Credentials) > 0) {
			return response{}, errors.New("no saveable harness changes; refresh the preview")
		}
		action = "save"
	case "discardHarnessChanges":
		if preview.State != "pending" {
			return response{}, errors.New("this candidate is no longer pending")
		}
		action = "discard"
	default:
		return response{}, errors.New("unsupported harness operation")
	}
	// Send the reviewed candidate only, once. Never submit token values, a TTL,
	// or private acknowledgment data, and never retry an ambiguous save.
	body, _ := json.Marshal(map[string]string{"candidateId": input.Candidate})
	result, err := b.call(ctx, "POST", path+"/"+action, body)
	if err != nil {
		return response{}, fmt.Errorf("%s may have succeeded; refresh the preview before retrying: %w", action, err)
	}
	return result, nil
}
