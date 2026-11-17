package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// Explicit, one-shot intents only. Never retry a lifecycle mutation.
func (b *Bridge) boxAction(ctx context.Context, req wire.Request) (wire.Response, error) {
	if err := ValidID(req.ProjectID); err != nil {
		return wire.Response{}, err
	}
	if err := ValidID(req.SandboxID); err != nil {
		return wire.Response{}, err
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
		res, err := b.Call(ctx, "GET", base, nil)
		if err != nil {
			return wire.Response{}, err
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
			return wire.Response{}, errors.New("invalid box state")
		}
		state := box.Runtime.DisplayState
		if state == "" {
			state = box.Runtime.State
		}
		if state != "archived" {
			return wire.Response{}, errors.New("only archived boxes can be purged from the desktop")
		}
	case "rename":
		name := strings.TrimSpace(req.Name)
		if name == "" || len(name) > 128 || strings.ContainsFunc(name, func(r rune) bool { return !unicode.IsPrint(r) }) {
			return wire.Response{}, errors.New("name must be one printable line of 1–128 bytes")
		}
		method, path = "PATCH", base+"/meta"
		body, _ = json.Marshal(map[string]string{"name": name})
	default:
		return wire.Response{}, errors.New("unsupported box action")
	}
	return b.Call(ctx, method, path, body)
}
