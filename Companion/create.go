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
	"time"

	api "github.com/discobox-ai/discobox/api/gen"
	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
	"github.com/discobox-ai/discobox/pkg/platform"
	"github.com/discobox-ai/discobox/pkg/sourceref"
)

func (b *bridge) createBox(ctx context.Context, req request) (out response, failure error) {
	if !b.allowManage {
		return response{}, errors.New("box creation requires explicit permission")
	}
	if validID(req.ProjectID) != nil || validID(req.HarnessID) != nil {
		return response{}, errors.New("invalid project or harness")
	}
	secrets, err := launchCredentials(req.Payload)
	if err != nil {
		return response{}, err
	}
	defer func() {
		if len(secrets) == 0 {
			return
		}
		if out.Status >= 400 {
			out.Body = []byte(redactLaunchCredentials(string(out.Body), secrets))
		}
		if failure != nil {
			failure = errors.New(redactLaunchCredentials(failure.Error(), secrets))
		}
	}()
	source := strings.TrimSpace(req.Repository)
	if source != "" {
		var err error
		source, err = repositorySource(source)
		if err != nil {
			return response{}, err
		}
	}
	harness, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/harness-configs/"+req.HarnessID, nil)
	if err != nil {
		return response{}, err
	}
	var h struct {
		Configured *bool `json:"configured"`
	}
	if harness.Status != 200 {
		return harness, nil
	}
	if json.Unmarshal(harness.Body, &h) != nil {
		return response{}, errors.New("invalid harness configuration response")
	}
	// New servers no longer require a separate setup step. Respect an older
	// server's explicit readiness flag when it is present.
	if h.Configured != nil && !*h.Configured {
		return response{}, errors.New("choose a configured harness")
	}
	if req.DiscoboxAPI != nil && *req.DiscoboxAPI && h.Configured != nil {
		return response{}, errors.New("this host uses the legacy harness API; update Discobox before enabling manager API access at launch")
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
	poolID := req.PoolID
	if poolID == "" {
		poolID = p.DefaultPoolID
	}
	if poolID != "" {
		if validID(poolID) != nil {
			return response{}, errors.New("invalid destination pool")
		}
		pool, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/pools/"+poolID, nil)
		if err != nil {
			return response{}, err
		}
		var data struct {
			Platform    string          `json:"platform"`
			Resources   json.RawMessage `json:"resources"`
			Schedulable *bool           `json:"schedulable"`
		}
		if pool.Status != 200 || json.Unmarshal(pool.Body, &data) != nil {
			return response{}, errors.New("could not read destination pool")
		}
		if data.Schedulable != nil && !*data.Schedulable {
			return response{}, errors.New("the selected pool is not accepting new boxes")
		}
		if reportedDataDiskFull(data.Resources, time.Now()) {
			return response{}, errors.New("the selected pool reports no available data disk space; manage its resources before creating a box (cache free space is not reported)")
		}
		if data.Platform != "" {
			target, err = platform.Parse(data.Platform)
			if err != nil {
				return response{}, err
			}
		}
	}
	options := sandboxcreate.PromptOptions{Source: source, NoSource: source == "", Platform: target, PoolID: poolID, IncludeDirty: sandboxcreate.IncludeDirtyNever}
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
	body.Config.Secrets = secrets
	if req.DiscoboxAPI != nil && *req.DiscoboxAPI {
		body.SetDiscoboxApi(api.NewOptBool(true))
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return response{}, err
	}
	// This application connects to different server releases. A successful
	// creation is not invalid merely because its harness snapshot has fields
	// removed from the current generated SDK. Keep the full receipt for the GUI
	// and decode only the state source delivery actually needs.
	result, err := b.call(ctx, "POST", "/projects/"+req.ProjectID+"/sandboxes", encoded)
	if err != nil {
		return response{}, fmt.Errorf("creation may have succeeded; refresh boxes before retrying: %w", err)
	}
	if result.Status < 200 || result.Status >= 300 {
		return result, nil
	}
	sandbox, err := decodeDeliverySandbox(result.Body, req.ProjectID, "")
	if err != nil {
		return response{}, fmt.Errorf("creation may have succeeded; refresh boxes before retrying: %w", err)
	}
	if source != "" {
		client, err := api.NewClient(b.base, api.WithClient(b.client))
		if err != nil {
			return response{}, fmt.Errorf("box %s created; source delivery could not start: %w", sandbox.ID, err)
		}
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
		// Keep authentication on this computer, as before. The newer delivery
		// API requires an explicit policy; this UI does not lend Git credentials.
		options := sandboxcreate.DeliveryOptions{Credentials: sandboxcreate.GitCredentialsLocal}
		delivery := sourceDeliveryClient{Client: client, bridge: b}
		if err := sandboxcreate.DeliverSource(ctx, delivery, req.ProjectID, sandbox, local, "http://"+listener.Addr().String(), "", nil, options); err != nil {
			return response{}, fmt.Errorf("box %s was created but source delivery failed; do not create again: %w", sandbox.ID, err)
		}
	}
	return result, nil
}

// The upstream source parser accepts Git's scp notation, but the API stores
// a URI and its serializer uses net/url. Normalize at the desktop boundary,
// before any source lookup or creation, preserving SSH, ref and subdirectory.
func repositorySource(value string) (string, error) {
	source, err := sandboxcreate.ParseSource(strings.TrimSpace(value))
	if err != nil || source.Kind != sourceref.Git {
		return "", errors.New("repository must be a remote Git URL or OWNER/REPO")
	}
	if !strings.Contains(source.Location, "://") {
		authority, remotePath, ok := strings.Cut(source.Location, ":")
		if !ok || remotePath == "" {
			return "", errors.New("SSH repository needs a host and repository path")
		}
		address, err := url.Parse("ssh://" + authority)
		if err != nil || address.Hostname() == "" || address.Path != "" || address.RawQuery != "" || address.Fragment != "" {
			return "", errors.New("invalid SSH repository address; use ssh://USER@HOST/PATH")
		}
		if !strings.HasPrefix(remotePath, "/") {
			switch strings.ToLower(address.Hostname()) {
			case "github.com", "gitlab.com", "bitbucket.org":
				// These hosts address virtual repositories as owner/name.
				remotePath = "/" + remotePath
			default:
				// On an ordinary SSH server, host:repo is relative to the
				// SSH user's home; ssh://host/repo would be absolute.
				if strings.HasPrefix(remotePath, "~") {
					remotePath = "/" + remotePath
				} else {
					remotePath = "/~/" + remotePath
				}
			}
		}
		address.Path = remotePath
		source.Location = address.String()
	}
	return source.String(), nil
}

// Source delivery has its own small read contract. Embedded harness, creator,
// pool and policy snapshots are unrelated to it and vary between releases.
// Do not decode full SDK config/runtime objects: they contain optional
// upgrade and harness metadata that has changed between server releases.
func decodeDeliverySandbox(data []byte, project, id string) (*api.Sandbox, error) {
	type sourceWire api.GitSource
	type deliveryWire api.SourceDelivery
	var wire struct {
		ID        string  `json:"id"`
		ProjectID string  `json:"projectId"`
		PoolID    *string `json:"poolId"`
		Config    *struct {
			Source               *sourceWire           `json:"source"`
			SourceCodeReferences map[string]sourceWire `json:"sourceCodeReferences"`
		} `json:"config"`
		Runtime *struct {
			State             string                  `json:"state"`
			DisplayState      *string                 `json:"displayState"`
			ErrorMessage      api.OptString           `json:"errorMessage"`
			SourceDeliveredAt api.OptDateTime         `json:"sourceDeliveredAt"`
			SourceDeliveries  map[string]deliveryWire `json:"sourceDeliveries"`
		} `json:"runtime"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, fmt.Errorf("invalid box response: %w", err)
	}
	if validID(wire.ID) != nil || wire.ProjectID != project || (id != "" && wire.ID != id) || wire.Config == nil || wire.Runtime == nil || wire.Runtime.State == "" {
		return nil, errors.New("invalid box identity or source-delivery state")
	}
	sandbox := &api.Sandbox{ID: wire.ID, ProjectId: wire.ProjectID}
	if wire.PoolID != nil {
		sandbox.PoolId.SetTo(*wire.PoolID)
	}
	if wire.Config.Source != nil {
		sandbox.Config.Source.SetTo(api.GitSource(*wire.Config.Source))
	}
	if wire.Config.SourceCodeReferences != nil {
		references := make(api.SandboxConfigSourceCodeReferences, len(wire.Config.SourceCodeReferences))
		for key, source := range wire.Config.SourceCodeReferences {
			references[key] = api.GitSource(source)
		}
		sandbox.Config.SourceCodeReferences.SetTo(references)
	}
	sandbox.Runtime.State = api.SandboxRuntimeState(wire.Runtime.State)
	if wire.Runtime.DisplayState != nil {
		sandbox.Runtime.DisplayState.SetTo(api.SandboxRuntimeDisplayState(*wire.Runtime.DisplayState))
	}
	sandbox.Runtime.ErrorMessage = wire.Runtime.ErrorMessage
	sandbox.Runtime.SourceDeliveredAt = wire.Runtime.SourceDeliveredAt
	if wire.Runtime.SourceDeliveries != nil {
		states := make(api.SandboxRuntimeSourceDeliveries, len(wire.Runtime.SourceDeliveries))
		for key, state := range wire.Runtime.SourceDeliveries {
			states[key] = api.SourceDelivery(state)
		}
		sandbox.Runtime.SourceDeliveries.SetTo(states)
	}
	return sandbox, nil
}

type sourceDeliveryClient struct {
	*api.Client
	bridge *bridge
}

func (c sourceDeliveryClient) GetSandbox(ctx context.Context, params api.GetSandboxParams) (api.GetSandboxRes, error) {
	if validID(params.ProjectId) != nil || validID(params.SandboxId) != nil {
		return nil, errors.New("invalid source-delivery destination")
	}
	result, err := c.bridge.call(ctx, "GET", "/projects/"+params.ProjectId+"/sandboxes/"+params.SandboxId, nil)
	if err != nil {
		return nil, err
	}
	if result.Status < 200 || result.Status >= 300 {
		return nil, fmt.Errorf("read created box: HTTP %d", result.Status)
	}
	return decodeDeliverySandbox(result.Body, params.ProjectId, params.SandboxId)
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
