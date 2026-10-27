package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode"
)

// Explicit, one-shot intents only. Never retry a lifecycle mutation.
func (b *bridge) boxAction(ctx context.Context, req request) (response, error) {
	if !b.allowManage {
		return response{}, errors.New("box actions require explicit permission")
	}
	if err := validID(req.ProjectID); err != nil {
		return response{}, err
	}
	if err := validID(req.SandboxID); err != nil {
		return response{}, err
	}
	base := "/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID
	method, path := "POST", base+"/"+req.Action
	var body []byte
	switch req.Action {
	case "start", "stop", "upgrade":
		body = []byte(`{}`)
	case "repair", "unarchive":
	case "archive":
		method, path = "DELETE", base
	case "purge":
		// The desktop exposes permanent deletion only for an archived box.
		res, err := b.call(ctx, "GET", base, nil)
		if err != nil {
			return response{}, err
		}
		if res.Status != 200 {
			return res, nil
		}
		var box struct {
			Runtime struct {
				State        string `json:"state"`
				DisplayState string `json:"displayState"`
			} `json:"runtime"`
		}
		if json.Unmarshal(res.Body, &box) != nil {
			return response{}, errors.New("invalid box state")
		}
		state := box.Runtime.DisplayState
		if state == "" {
			state = box.Runtime.State
		}
		if state != "archived" {
			return response{}, errors.New("only archived boxes can be purged from the desktop")
		}
	case "rename":
		name := strings.TrimSpace(req.Prompt)
		if name == "" || len(name) > 128 || strings.ContainsFunc(name, func(r rune) bool { return !unicode.IsPrint(r) }) {
			return response{}, errors.New("name must be one printable line of 1–128 bytes")
		}
		method, path = "PATCH", base+"/meta"
		body, _ = json.Marshal(map[string]string{"name": name})
	default:
		return response{}, errors.New("unsupported box action")
	}
	return b.call(ctx, method, path, body)
}
