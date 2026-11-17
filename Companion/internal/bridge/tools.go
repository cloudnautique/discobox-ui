package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strings"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

type declaredTool struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Runs    string   `json:"runs"`
	Problem string   `json:"problem"`
	Script  bool     `json:"script"`
	Path    string   `json:"path"`
	Program []string `json:"program"`
	Args    []string `json:"args"`
	Env     []string `json:"env"`
	Files   []struct {
		Home    string `json:"home"`
		Default string `json:"default"`
	} `json:"files"`
}

func (b *Bridge) toolOperation(ctx context.Context, req wire.Request) (wire.Response, error) {
	if ValidID(req.ProjectID) != nil || ValidID(req.SandboxID) != nil {
		return wire.Response{}, errors.New("invalid box")
	}
	if err := b.RequireRunningBox(ctx, req); err != nil {
		return wire.Response{}, err
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID
	if req.Operation == "tools" {
		return b.Call(ctx, "GET", base+"/tools", nil)
	}
	body := map[string]any{"tty": true, "cols": 100, "rows": 30, "env": map[string]string{"TERM": "xterm-256color"}}
	if req.Operation == "openTool" {
		// Reuse only a live matching session. Never revive an ended tool implicitly.
		existing, err := b.Call(ctx, "GET", base+"/execs", nil)
		if err != nil {
			return wire.Response{}, err
		}
		var listing struct {
			Execs      []json.RawMessage `json:"execs"`
			ObservedAt *string           `json:"observedAt"`
		}
		if existing.Status != 200 || json.Unmarshal(existing.Body, &listing) != nil || listing.ObservedAt != nil {
			return wire.Response{}, errors.New("live terminal inventory unavailable")
		}
		for _, raw := range listing.Execs {
			var e struct {
				Status   string            `json:"status"`
				Metadata map[string]string `json:"metadata"`
			}
			if json.Unmarshal(raw, &e) == nil && e.Status == "running" && e.Metadata["tool"] == req.ToolID && req.Action != "review" && e.Metadata["review"] != "true" {
				return wire.Response{Version: wire.ProtocolVersion, Status: 200, Body: raw}, nil
			}
		}
		catalog, err := b.Call(ctx, "GET", base+"/tools", nil)
		if err != nil {
			return wire.Response{}, err
		}
		var list struct {
			Tools      []declaredTool `json:"tools"`
			ObservedAt *string        `json:"observedAt"`
		}
		if catalog.Status != 200 || json.Unmarshal(catalog.Body, &list) != nil || list.ObservedAt != nil {
			return wire.Response{}, errors.New("live tool catalog unavailable")
		}
		var tool *declaredTool
		// Source declarations override the image's declaration.
		for i := range list.Tools {
			if list.Tools[i].ID == req.ToolID && list.Tools[i].Problem == "" {
				tool = &list.Tools[i]
			}
		}
		if tool == nil || tool.Runs != "sandbox" {
			return wire.Response{}, errors.New("tool is unavailable or requires a host launcher")
		}
		command := tool.Program
		if tool.Script {
			command = []string{tool.Path}
		}
		if len(command) == 0 || command[0] == "" {
			return wire.Response{}, errors.New("tool has no program")
		}
		command = append(command, tool.Args...)
		// Optional explicit base/head review uses the image's review program contract.
		if req.Action == "review" {
			var refs struct {
				Base string `json:"base"`
				Head string `json:"head"`
			}
			if err := json.Unmarshal(req.Payload, &refs); err != nil {
				return wire.Response{}, err
			}
			if refs.Base == "" || refs.Head == "" || strings.HasPrefix(refs.Base, "-") || strings.HasPrefix(refs.Head, "-") {
				return wire.Response{}, errors.New("supply base and head refs")
			}
			command = []string{"discobox-review", "-by", "git-user", "-base", refs.Base, "-head", refs.Head}
		}
		env := map[string]string{"TERM": "xterm-256color"}
		for _, pair := range tool.Env {
			k, v, ok := strings.Cut(pair, "=")
			if ok && k != "" {
				env[k] = v
			}
		}
		for _, file := range tool.Files {
			clean := path.Clean(file.Home)
			if clean == "." || path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
				return wire.Response{}, errors.New("tool file escapes home")
			}
			destination := "~/" + clean
			parent, _ := json.Marshal(map[string]any{"path": path.Dir(destination), "parents": true})
			mkdir, err := b.Call(ctx, "POST", base+"/files/mkdir", parent)
			if err != nil {
				return wire.Response{}, err
			}
			if mkdir.Status < 200 || mkdir.Status >= 300 {
				return mkdir, nil
			}
			result, err := b.Call(ctx, "PUT", base+"/files/content?path="+url.QueryEscape(destination)+"&ifExists=fail", []byte(file.Default))
			if err != nil {
				return wire.Response{}, err
			}
			if (result.Status < 200 || result.Status >= 300) && result.Status != 412 {
				return result, nil
			}
		}
		body["command"] = command
		body["env"] = env
		metadata := map[string]string{"tool": tool.ID}
		if req.Action == "review" {
			metadata["review"] = "true"
		}
		body["metadata"] = metadata
	}
	payload, _ := json.Marshal(body)
	created, err := b.Call(ctx, "POST", base+"/execs?wait=ready", payload)
	if err != nil {
		return wire.Response{}, fmt.Errorf("session creation may have succeeded; refresh before retrying: %w", err)
	}
	if created.Status < 200 || created.Status >= 300 {
		return created, nil
	}
	var made struct {
		Exec struct {
			ID      string `json:"id"`
			Primary bool   `json:"primary"`
		} `json:"exec"`
	}
	if json.Unmarshal(created.Body, &made) != nil || ValidID(made.Exec.ID) != nil || made.Exec.Primary || made.Exec.ID == "primary" {
		return wire.Response{}, errors.New("invalid new terminal")
	}
	started, err := b.Call(ctx, "POST", base+"/execs/"+made.Exec.ID+"/start", nil)
	if err != nil {
		return wire.Response{}, fmt.Errorf("session %s was created; refresh before retrying: %w", made.Exec.ID, err)
	}
	if started.Status < 200 || started.Status >= 300 {
		return started, nil
	}
	return b.Call(ctx, "GET", base+"/execs/"+made.Exec.ID, nil)
}
