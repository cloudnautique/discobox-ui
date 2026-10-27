package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"runtime"
	"strings"

	api "github.com/discobox-ai/discobox/api/gen"
	model "github.com/discobox-ai/discobox/api/model"
	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
	"github.com/discobox-ai/discobox/pkg/platform"
	"github.com/discobox-ai/discobox/pkg/sourceref"
)

func (b *bridge) createBox(ctx context.Context, req request) (response, error) {
	if !b.allowManage {
		return response{}, errors.New("box creation requires explicit permission")
	}
	if validID(req.ProjectID) != nil || validID(req.HarnessID) != nil {
		return response{}, errors.New("invalid project or harness")
	}
	source := strings.TrimSpace(req.Repository)
	if source != "" {
		parsed, err := sandboxcreate.ParseSource(source)
		if err != nil || parsed.Kind != sourceref.Git {
			return response{}, errors.New("repository must be a remote Git URL or OWNER/REPO")
		}
		source = parsed.String()
	}
	harness, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/harness-configs/"+req.HarnessID, nil)
	if err != nil {
		return response{}, err
	}
	var h struct {
		Configured bool `json:"configured"`
	}
	if harness.Status != 200 {
		return harness, nil
	}
	if json.Unmarshal(harness.Body, &h) != nil {
		return response{}, errors.New("invalid harness configuration response")
	}
	if !h.Configured {
		return response{}, errors.New("choose a configured harness")
	}
	target := platform.Platform{OS: "linux", Arch: runtime.GOARCH}
	project, err := b.call(ctx, "GET", "/projects/"+req.ProjectID, nil)
	if err != nil {
		return response{}, err
	}
	var p struct {
		DefaultPoolID string `json:"defaultPoolId"`
	}
	if project.Status != 200 || json.Unmarshal(project.Body, &p) != nil {
		return response{}, errors.New("could not read project placement")
	}
	if p.DefaultPoolID != "" {
		if validID(p.DefaultPoolID) != nil {
			return response{}, errors.New("invalid default pool")
		}
		pool, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/pools/"+p.DefaultPoolID, nil)
		if err != nil {
			return response{}, err
		}
		var data struct {
			Platform string `json:"platform"`
		}
		if pool.Status != 200 || json.Unmarshal(pool.Body, &data) != nil {
			return response{}, errors.New("could not read default pool platform")
		}
		if data.Platform != "" {
			target, err = platform.Parse(data.Platform)
			if err != nil {
				return response{}, err
			}
		}
	}
	client, err := api.NewClient(b.base, api.WithClient(b.client))
	if err != nil {
		return response{}, err
	}
	options := sandboxcreate.PromptOptions{Source: source, NoSource: source == "", Platform: target, IncludeDirty: sandboxcreate.IncludeDirtyNever}
	if strings.TrimSpace(req.Prompt) != "" {
		options.Prompt = []string{req.Prompt}
	}
	body, local, err := sandboxcreate.BuildPromptSandboxBody(ctx, options)
	if err != nil {
		return response{}, err
	}
	defer local.Close()
	// The picker supplies an exact config ID, not a CLI name selector. Keep
	// that identity explicit, including on servers whose name resolver only
	// accepts slugs/names. Source preparation must not choose another harness.
	body.HarnessName = api.OptString{}
	body.Config.HarnessConfigId = api.NewOptString(req.HarnessID)
	result, err := client.CreateSandbox(ctx, body, api.CreateSandboxParams{ProjectId: req.ProjectID})
	if err != nil {
		return response{}, fmt.Errorf("creation may have succeeded; refresh boxes before retrying: %w", err)
	}
	sandbox, ok := result.(*model.Sandbox)
	if !ok {
		if problem, ok := result.(*api.ErrorModelStatusCode); ok {
			data, err := json.Marshal(&problem.Response)
			return response{Version: 1, Status: problem.StatusCode, Body: data}, err
		}
		return response{}, fmt.Errorf("unexpected create-box response (%T); refresh boxes before retrying", result)
	}
	if source != "" {
		// Git only speaks HTTP. This short-lived loopback proxy permits Git routes
		// for this one newly-created box, using the existing socket transport.
		base, _ := url.Parse(b.base)
		proxy := httputil.NewSingleHostReverseProxy(base)
		proxy.Transport = b.client.Transport
		prefix := "/projects/" + req.ProjectID + "/sandboxes/" + sandbox.ID + "/"
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return response{}, fmt.Errorf("box %s created; source delivery failed: %w", sandbox.ID, err)
		}
		server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			route := strings.TrimPrefix(r.URL.Path, prefix)
			if path.Clean(r.URL.Path) != r.URL.Path || (r.Method != "GET" && r.Method != "POST") || !strings.HasPrefix(r.URL.Path, prefix) || !(strings.HasPrefix(route, "git-origins/") || strings.HasPrefix(route, "git-caches/") || strings.HasPrefix(route, "git/")) {
				http.NotFound(w, r)
				return
			}
			proxy.ServeHTTP(w, r)
		})}
		go server.Serve(listener)
		defer server.Close()
		if err := sandboxcreate.DeliverSource(ctx, client, req.ProjectID, sandbox, local, "http://"+listener.Addr().String(), "", nil); err != nil {
			return response{}, fmt.Errorf("box %s was created but source delivery failed; do not create again: %w", sandbox.ID, err)
		}
	}
	data, err := json.Marshal(sandbox)
	return response{Version: 1, Status: 200, Body: data}, err
}

func (b *bridge) closeShell(ctx context.Context, req request) (response, error) {
	if !b.allowManage {
		return response{}, errors.New("closing a shell requires explicit permission")
	}
	for _, id := range []string{req.ProjectID, req.SandboxID, req.ExecID} {
		if validID(id) != nil {
			return response{}, errors.New("invalid shell identity")
		}
	}
	if req.ExecID == "primary" {
		return response{}, errors.New("cannot close the agent")
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/execs/" + req.ExecID
	record, err := b.call(ctx, "GET", base, nil)
	if err != nil {
		return response{}, err
	}
	var exec struct {
		Primary          bool    `json:"primary"`
		TTY              bool    `json:"tty"`
		HarnessID        string  `json:"harnessId"`
		CurrentHarnessID string  `json:"currentHarnessId"`
		ObservedAt       *string `json:"observedAt"`
	}
	if record.Status != 200 || json.Unmarshal(record.Body, &exec) != nil || exec.Primary || !exec.TTY || (req.Operation != "closeTerminal" && (exec.HarnessID != "" || exec.CurrentHarnessID != "")) || exec.ObservedAt != nil {
		return response{}, errors.New("only a live shell terminal can be closed")
	}
	return b.call(ctx, "DELETE", base, nil)
}
