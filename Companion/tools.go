package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strings"
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

func (b *bridge) toolOperation(ctx context.Context, req request) (response, error) {
	if validID(req.ProjectID) != nil || validID(req.SandboxID) != nil {
		return response{}, errors.New("invalid box")
	}
	if err := b.requireRunningBox(ctx, req); err != nil {
		return response{}, err
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID
	if req.Operation == "tools" {
		return b.call(ctx, "GET", base+"/tools", nil)
	}
	if !b.allowManage {
		return response{}, errors.New("opening a tool or harness requires explicit permission")
	}
	body := map[string]any{"tty": true, "cols": 100, "rows": 30, "env": map[string]string{"TERM": "xterm-256color"}}
	if req.Operation == "openTool" {
		// Reuse only a live matching session. Never revive an ended tool implicitly.
		existing, err := b.call(ctx, "GET", base+"/execs", nil)
		if err != nil {
			return response{}, err
		}
		var listing struct {
			Execs      []json.RawMessage `json:"execs"`
			ObservedAt *string           `json:"observedAt"`
		}
		if existing.Status != 200 || json.Unmarshal(existing.Body, &listing) != nil || listing.ObservedAt != nil {
			return response{}, errors.New("live terminal inventory unavailable")
		}
		for _, raw := range listing.Execs {
			var e struct {
				Status   string            `json:"status"`
				Metadata map[string]string `json:"metadata"`
			}
			if json.Unmarshal(raw, &e) == nil && e.Status == "running" && e.Metadata["tool"] == req.Kind && req.Action != "review" && e.Metadata["review"] != "true" {
				return response{Version: 1, Status: 200, Body: raw}, nil
			}
		}
		catalog, err := b.call(ctx, "GET", base+"/tools", nil)
		if err != nil {
			return response{}, err
		}
		var list struct {
			Tools      []declaredTool `json:"tools"`
			ObservedAt *string        `json:"observedAt"`
		}
		if catalog.Status != 200 || json.Unmarshal(catalog.Body, &list) != nil || list.ObservedAt != nil {
			return response{}, errors.New("live tool catalog unavailable")
		}
		var tool *declaredTool
		// Source declarations override the image's declaration.
		for i := range list.Tools {
			if list.Tools[i].ID == req.Kind && list.Tools[i].Problem == "" {
				tool = &list.Tools[i]
			}
		}
		if tool == nil || tool.Runs != "sandbox" {
			return response{}, errors.New("tool is unavailable or requires a host launcher")
		}
		command := tool.Program
		if tool.Script {
			command = []string{tool.Path}
		}
		if len(command) == 0 || command[0] == "" {
			return response{}, errors.New("tool has no program")
		}
		command = append(command, tool.Args...)
		// Optional explicit base/head review uses the image's review program contract.
		if req.Action == "review" {
			var refs struct {
				Base string `json:"base"`
				Head string `json:"head"`
			}
			if err := json.Unmarshal(req.Payload, &refs); err != nil {
				return response{}, err
			}
			if refs.Base == "" || refs.Head == "" || strings.HasPrefix(refs.Base, "-") || strings.HasPrefix(refs.Head, "-") {
				return response{}, errors.New("supply base and head refs")
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
				return response{}, errors.New("tool file escapes home")
			}
			destination := "~/" + clean
			parent, _ := json.Marshal(map[string]any{"path": path.Dir(destination), "parents": true})
			mkdir, err := b.call(ctx, "POST", base+"/files/mkdir", parent)
			if err != nil {
				return response{}, err
			}
			if mkdir.Status < 200 || mkdir.Status >= 300 {
				return mkdir, nil
			}
			result, err := b.call(ctx, "PUT", base+"/files/content?path="+url.QueryEscape(destination)+"&ifExists=fail", []byte(file.Default))
			if err != nil {
				return response{}, err
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
	created, err := b.call(ctx, "POST", base+"/execs?wait=ready", payload)
	if err != nil {
		return response{}, fmt.Errorf("session creation may have succeeded; refresh before retrying: %w", err)
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
	if json.Unmarshal(created.Body, &made) != nil || validID(made.Exec.ID) != nil || made.Exec.Primary || made.Exec.ID == "primary" {
		return response{}, errors.New("invalid new terminal")
	}
	started, err := b.call(ctx, "POST", base+"/execs/"+made.Exec.ID+"/start", nil)
	if err != nil {
		return response{}, fmt.Errorf("session %s was created; refresh before retrying: %w", made.Exec.ID, err)
	}
	if started.Status < 200 || started.Status >= 300 {
		return started, nil
	}
	return b.call(ctx, "GET", base+"/execs/"+made.Exec.ID, nil)
}
