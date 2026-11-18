// Package bridge serves the companion's bounded requests: one wire.Request
// from stdin, one wire.Response to stdout. It owns the HTTP transport to an
// existing Discobox endpoint (endpoint resolution, redirect refusal, body
// limits), the operation registry with each operation's permission class and
// deadline (operations.go, published in Companion/protocol.json), and the
// handlers. The long-lived modes reuse its transport through New, Call and
// the running-state checks.
package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
	serverendpoint "github.com/discobox-ai/discobox/pkg/endpoint"
)

const maxBody = 8 << 20

// Bridge is one process's HTTP client for an existing Discobox endpoint.
type Bridge struct {
	client      *http.Client
	base        string
	allowShell  bool
	allowManage bool
}

// HTTPClient is the endpoint's client; a Unix socket endpoint dials its socket.
func (b *Bridge) HTTPClient() *http.Client { return b.client }

// BaseURL prefixes every request path (http://discobox.local for a socket).
func (b *Bridge) BaseURL() string { return b.base }

// RunManaged decodes exactly one request from input, checks its operation's
// permission flag and runs it under the operation's deadline.

func RunManaged(endpoint string, allowShell, allowManage bool, input io.Reader, out *wire.Response) error {
	var req wire.Request
	decoder := json.NewDecoder(io.LimitReader(input, 128<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		return fmt.Errorf("invalid request: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("expected one request")
	}
	b, err := New(endpoint)
	if err != nil {
		return err
	}
	b.allowShell = allowShell
	b.allowManage = allowManage
	defer b.client.CloseIdleConnections()
	op, err := lookupOperation(req.Operation)
	if err != nil {
		return err
	}
	op.configure(b.client)
	parent, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	ctx, cancel := context.WithTimeout(parent, op.deadlineFor(req))
	defer cancel()
	finish := readDiagnostics(endpoint, req)
	result, err := b.dispatch(ctx, op, req)
	finish(result.Status, len(result.Body), err)
	if err != nil {
		return err
	}
	// The wire version belongs to this process boundary. Assembled responses
	// (harness metadata, credential previews) do not pass through b.Call.
	result.Version = wire.ProtocolVersion
	*out = result
	return nil
}

// One bounded record pair per observed read gives counts by operation and
// trigger. Only known operation names reach the log, never the payload.
func readDiagnostics(endpoint string, req wire.Request) func(int, int, error) {
	trigger := os.Getenv("DISCOBOX_UI_READ_TRIGGER")
	if trigger == "scheduled" || trigger == "requested" {
		switch req.Operation {
		case "execs", "services", "usage", "usageHeaders", "auditBody", "approvals", "poolResources", "sandboxes":
			stop := diagnostics.Start("metadata", endpoint, os.Getenv("DISCOBOX_UI_GENERATION"), req)
			started := time.Now()
			diagnostics.Emit(diagnostics.Event{Event: "read_" + req.Operation, Reason: trigger})
			return func(status, size int, err error) {
				diagnostics.Emit(diagnostics.Event{Event: "read_finished", Received: int64(size), HTTPStatus: status, Reason: diagnostics.Reason(err), DurationMS: time.Since(started).Milliseconds()})
				stop()
			}
		}
	}
	return func(int, int, error) {}
}

// ResolveEndpoint expands the default local shorthand (empty or unix://)
// through pkg/endpoint, including DISCOBOX_SERVER_ADDRESS.
func ResolveEndpoint(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" || value == "unix://" {
		return serverendpoint.DefaultEndpoint()
	}
	return value
}

func defaultSocket() string {
	parsed, err := serverendpoint.Parse(serverendpoint.DefaultEndpoint())
	if err != nil || parsed.Scheme != "unix" {
		return ""
	}
	return parsed.Value
}

// New validates endpoint and builds its client. Redirects are refused.
func New(endpoint string) (*Bridge, error) {
	u, err := url.Parse(ResolveEndpoint(endpoint))
	if err != nil {
		return nil, fmt.Errorf("invalid endpoint: %w", err)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.ResponseHeaderTimeout = 10 * time.Second
	transport.MaxResponseHeaderBytes = 64 << 10
	base := strings.TrimRight(u.String(), "/")
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
		return nil, errors.New("endpoint must not contain credentials, a query, or a fragment")
	}
	switch u.Scheme {
	case "unix":
		if u.Host != "" {
			return nil, errors.New("use unix:///absolute/socket/path or unix://")
		}
		path := u.Path
		if path == "" {
			parsed, parseErr := serverendpoint.Parse(u.String())
			if parseErr != nil {
				return nil, parseErr
			}
			path = parsed.Value
		}
		if !filepath.IsAbs(path) {
			return nil, errors.New("Unix socket path must be absolute")
		}
		transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", path)
		}
		base = "http://discobox.local"
	case "http", "https":
		if u.Hostname() == "" {
			return nil, errors.New("endpoint requires a hostname")
		}
	default:
		return nil, errors.New("this build supports unix:// and existing http:// or https:// endpoints; Iroh connections use the app's private transport")
	}
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return wire.ErrEndpointRedirect },
	}
	return &Bridge{client: client, base: base}, nil
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// ValidID accepts only identifiers safe to place in a request path.
func ValidID(id string) error {
	if len(id) > 256 || !identifier.MatchString(id) {
		return errors.New("invalid resource identifier")
	}
	return nil
}

func route(req wire.Request) (method, path string, body []byte, err error) {
	method = http.MethodGet
	if req.Operation == "serverPeer" {
		return method, "/peer", nil, nil
	}
	if req.Operation == "defaultProject" {
		return method, "/projects/default", nil, nil
	}
	if err = ValidID(req.ProjectID); err != nil {
		return
	}
	project := "/projects/" + req.ProjectID
	if req.Operation == "harnesses" {
		return method, project + "/harness-configs", nil, nil
	}
	if req.Operation == "sandboxes" {
		return method, project + "/sandboxes", nil, nil
	}
	if err = ValidID(req.SandboxID); err != nil {
		return
	}
	base := "/api" + project + "/sandboxes/" + req.SandboxID
	switch req.Operation {
	case "execs", "services":
		return method, base + "/" + req.Operation, nil, nil
	case "screen":
		if err = ValidID(req.ExecID); err != nil {
			return
		}
		if req.ExecID == "primary" {
			err = errors.New("select a concrete exec; virtual primary is not supported")
			return
		}
		path = base + "/execs/" + req.ExecID + "/" + req.Operation
		return method, path + "?scrollback=250", nil, nil
	default:
		return "", "", nil, errors.New("unsupported operation; lifecycle and arbitrary HTTP requests are not exposed")
	}
}

// routed serves the plain resource reads in route().
func (b *Bridge) routed(ctx context.Context, req wire.Request) (wire.Response, error) {
	method, path, body, err := route(req)
	if err != nil {
		return wire.Response{}, err
	}
	res, err := b.Call(ctx, method, path, body)
	if req.Operation == "sandboxes" && err == nil && res.Status == 200 {
		res.Body = withPreparationStatus(res.Body)
	}
	return res, err
}

// RequireRunningBox fails unless the box reports a running runtime.
func (b *Bridge) RequireRunningBox(ctx context.Context, req wire.Request) error {
	box, err := b.Call(ctx, "GET", "/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID, nil)
	if err != nil {
		return err
	}
	var state struct {
		Runtime struct {
			RuntimeState string `json:"runtimeState"`
		} `json:"runtime"`
	}
	if box.Status != 200 || json.Unmarshal(box.Body, &state) != nil || state.Runtime.RuntimeState != "running" {
		return errors.New("input requires a currently running box")
	}
	return nil
}

// RequireRunning fails unless the box is running and its concrete terminal is
// live, running and a TTY.
func (b *Bridge) RequireRunning(ctx context.Context, req wire.Request) error {
	if err := b.RequireRunningBox(ctx, req); err != nil {
		return err
	}
	exec, err := b.Call(ctx, "GET", "/api/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID+"/execs/"+req.ExecID, nil)
	if err != nil {
		return err
	}
	var terminal struct {
		Status     string  `json:"status"`
		ObservedAt *string `json:"observedAt"`
		TTY        bool    `json:"tty"`
	}
	if exec.Status != 200 || json.Unmarshal(exec.Body, &terminal) != nil || terminal.Status != "running" || terminal.ObservedAt != nil || !terminal.TTY {
		return errors.New("input requires a live, running terminal")
	}
	return nil
}

// Call makes one request to the endpoint, reading at most 8 MiB of body.
func (b *Bridge) Call(ctx context.Context, method, path string, body []byte) (wire.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, b.base+path, bytes.NewReader(body))
	if err != nil {
		return wire.Response{}, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		if method == "PUT" && strings.Contains(path, "/files/content?") {
			req.Header.Set("Content-Type", "application/octet-stream")
		}
	}
	res, err := b.client.Do(req)
	if err != nil {
		return wire.Response{}, fmt.Errorf("existing server request failed: %w", err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, maxBody+1))
	if err != nil {
		return wire.Response{}, err
	}
	if len(data) > maxBody {
		return wire.Response{}, errors.New("response exceeds 8 MiB")
	}
	return wire.Response{Version: wire.ProtocolVersion, Status: res.StatusCode, Body: data}, nil
}

// ServerErrorMessage unwraps the {"error": "..."} body every hop in the chain
// answers with, so the line a user reads is the reason rather than the
// envelope it arrived in.
func ServerErrorMessage(body []byte) string {
	var wrapped struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil && strings.TrimSpace(wrapped.Error) != "" {
		return strings.TrimSpace(wrapped.Error)
	}
	return strings.TrimSpace(string(body))
}

// Only a new shell can be created/started, in one explicit authorized request.
// There is intentionally no general exec-start operation.
func (b *Bridge) newShell(ctx context.Context, req wire.Request) (wire.Response, error) {
	if err := ValidID(req.ProjectID); err != nil {
		return wire.Response{}, err
	}
	if err := ValidID(req.SandboxID); err != nil {
		return wire.Response{}, err
	}
	if err := b.RequireRunningBox(ctx, req); err != nil {
		return wire.Response{}, err
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/execs"
	created, err := b.Call(ctx, "POST", base+"?wait=ready", []byte(`{"shell":true,"tty":true,"cols":100,"rows":30,"env":{"TERM":"xterm-256color"}}`))
	if err != nil {
		return wire.Response{}, fmt.Errorf("shell creation may have succeeded; refresh terminals before retrying: %w", err)
	}
	if created.Status < 200 || created.Status >= 300 {
		return created, nil
	}
	var record struct {
		Exec struct {
			ID      string `json:"id"`
			Primary bool   `json:"primary"`
		} `json:"exec"`
	}
	if err := json.Unmarshal(created.Body, &record); err != nil {
		return wire.Response{}, err
	}
	id := record.Exec.ID
	if ValidID(id) != nil || id == "primary" || record.Exec.Primary {
		return wire.Response{}, errors.New("invalid new shell identity")
	}
	// Start only the shell returned by this request, never an existing terminal.
	started, err := b.Call(ctx, "POST", base+"/"+id+"/start", nil)
	if err != nil {
		return wire.Response{}, fmt.Errorf("shell %s was created; refresh before retrying: %w", id, err)
	}
	if started.Status < 200 || started.Status >= 300 {
		return started, nil
	}
	return b.Call(ctx, "GET", base+"/"+id, nil)
}
