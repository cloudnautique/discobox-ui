package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"time"

	"github.com/discobox-ai/discobox/pkg/bindingplan"
)

type approvalContext struct {
	Request     json.RawMessage   `json:"request"`
	Secrets     []json.RawMessage `json:"secrets"`
	Held        []json.RawMessage `json:"held"`
	Bindings    []json.RawMessage `json:"bindings"`
	Fingerprint string            `json:"fingerprint"`
	Use         bindingplan.Plan  `json:"usePlan"`
	Delegate    bindingplan.Plan  `json:"delegatePlan"`
}

// A read-only, request-scoped snapshot. Always use the requester from the
// server, never whichever box happens to be selected in the workspace.
func (b *bridge) credentialContext(ctx context.Context, req request) (approvalContext, response, error) {
	var out approvalContext
	if validID(req.RequestID) != nil {
		return out, response{}, errors.New("invalid request")
	}
	base := "/projects/" + req.ProjectID
	current, err := b.call(ctx, "GET", base+"/secret-requests/"+req.RequestID, nil)
	if err != nil || current.Status != 200 {
		return out, current, err
	}
	var ask struct {
		Sandbox string `json:"sandboxId"`
		Env     string `json:"envName"`
		Status  string `json:"status"`
	}
	if err = json.Unmarshal(current.Body, &ask); err != nil {
		return out, response{}, err
	}
	if ask.Status != "pending" {
		return out, response{}, errors.New("request is no longer pending")
	}
	out.Request = current.Body
	var paths = []string{base + "/secrets"}
	if ask.Sandbox != "" {
		if validID(ask.Sandbox) != nil {
			return out, response{}, errors.New("invalid requesting box")
		}
		query := "?targetKind=sandbox&target=" + url.QueryEscape(ask.Sandbox)
		paths = append(paths, base+"/bound-secrets"+query, base+"/secret-bindings"+query)
	}
	for i, path := range paths {
		res, e := b.call(ctx, "GET", path, nil)
		if e != nil || res.Status != 200 {
			return out, res, e
		}
		var list map[string]json.RawMessage
		if e = json.Unmarshal(res.Body, &list); e != nil {
			return out, response{}, e
		}
		switch i {
		case 0:
			err = json.Unmarshal(list["secrets"], &out.Secrets)
		case 1:
			err = json.Unmarshal(list["boundSecrets"], &out.Held)
		case 2:
			err = json.Unmarshal(list["secretBindings"], &out.Bindings)
		}
		if err != nil {
			return out, response{}, err
		}
	}
	// Canonicalize JSON before hashing, excluding the candidate decision. Any
	// metadata/binding change invalidates the review before a write can occur.
	raw, _ := json.Marshal(out)
	var canonical any
	_ = json.Unmarshal(raw, &canonical)
	raw, _ = json.Marshal(canonical)
	hash := sha256.Sum256(raw)
	out.Fingerprint = hex.EncodeToString(hash[:])
	var candidate struct {
		Secret string `json:"secretId"`
		Use    struct {
			Decision string `json:"decision"`
			As       string `json:"as"`
		} `json:"use"`
		Delegate struct {
			Decision string `json:"decision"`
		} `json:"delegate"`
	}
	if len(req.Payload) > 0 {
		if err = json.Unmarshal(req.Payload, &candidate); err != nil {
			return out, response{}, err
		}
	}
	var standing []bindingplan.Binding
	for _, raw := range out.Bindings {
		var row struct {
			ID, SecretID, TargetKind, TargetID, EnvVar string
			Use, Delegate, Adds                        bool
			CreatedAt                                  time.Time
		}
		if err = json.Unmarshal(raw, &row); err != nil {
			return out, response{}, err
		}
		if row.SecretID == candidate.Secret && row.TargetKind == "sandbox" && row.TargetID == ask.Sandbox {
			standing = append(standing, bindingplan.Binding{ID: row.ID, Use: row.Use, Delegate: row.Delegate, Adds: row.Adds, EnvName: row.EnvVar, Created: row.CreatedAt})
		}
	}
	var as bindingplan.As
	if candidate.Use.Decision == "approve" {
		as = bindingplan.As(candidate.Use.As)
		if as == "" {
			as = bindingplan.Replace
		}
	}
	out.Use, out.Delegate = bindingplan.Answer(standing, ask.Env, as, candidate.Delegate.Decision == "approve")
	return out, response{}, nil
}

func (b *bridge) previewCredential(ctx context.Context, req request) (response, error) {
	out, res, err := b.credentialContext(ctx, req)
	if err != nil || res.Status != 0 {
		return res, err
	}
	body, err := json.Marshal(out)
	return response{Status: 200, Body: body}, err
}

// Wrap only the desktop's modern form payload; the server receives its exact
// documented body. Re-read limits and standing grants immediately before POST.
func (b *bridge) reviewedCredential(ctx context.Context, req request) (json.RawMessage, response, error) {
	var review struct {
		Approval    json.RawMessage `json:"approval"`
		Fingerprint string          `json:"contextFingerprint"`
	}
	if err := json.Unmarshal(req.Payload, &review); err != nil {
		return nil, response{}, err
	}
	if review.Fingerprint == "" || len(review.Approval) == 0 {
		return nil, response{}, errors.New("review the credential's current routes and bindings before approving")
	}
	snapshot, res, err := b.credentialContext(ctx, req)
	if err != nil || res.Status != 0 {
		return nil, res, err
	}
	if snapshot.Fingerprint != review.Fingerprint {
		return nil, response{}, errors.New("the credential or its bindings changed; reload and review the effect before applying")
	}
	return review.Approval, response{}, nil
}
