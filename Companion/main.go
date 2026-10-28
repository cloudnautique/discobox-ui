// discobox-desktop-bridge is a bounded, unprivileged client. It never runs the
// general-purpose Discobox CLI or launches a backend. Explicit repository delivery uses a
// temporary loopback Git proxy scoped to the newly created box.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const maxBody = 8 << 20

type request struct {
	RemotePath string          `json:"remotePath,omitempty"`
	LocalPath  string          `json:"localPath,omitempty"`
	Operation  string          `json:"operation"`
	ProjectID  string          `json:"projectID"`
	SandboxID  string          `json:"sandboxID"`
	ExecID     string          `json:"execID"`
	HarnessID  string          `json:"harnessID,omitempty"`
	Repository string          `json:"repository,omitempty"`
	Prompt     string          `json:"prompt,omitempty"`
	RequestID  string          `json:"requestID,omitempty"`
	Kind       string          `json:"kind,omitempty"`
	Action     string          `json:"action,omitempty"`
	Payload    json.RawMessage `json:"payload,omitempty"`
	Input      []inputPart     `json:"input,omitempty"`
}

type inputPart struct {
	Text *string `json:"text,omitempty"`
	Key  *string `json:"key,omitempty"`
}

type response struct {
	Version int    `json:"version"`
	Status  int    `json:"status"`
	Body    []byte `json:"body,omitempty"`
	Error   string `json:"error,omitempty"`
}

type bridge struct {
	client      *http.Client
	base        string
	allowInput  bool
	allowShell  bool
	allowManage bool
}

func main() {
	irohProxy := flag.Bool("iroh-proxy", false, "Keep an authenticated Iroh connection behind a private socket")
	irohIdentity := flag.Bool("iroh-identity", false, "Print the public identity supplied over stdin")
	endpoint := flag.String("endpoint", "unix://", "An existing Discobox endpoint")
	allowInput := flag.Bool("allow-input", false, "Allow one explicit terminal input request")
	desktop := flag.Bool("desktop", false, "Embed the existing desktop viewer with a native clipboard bridge")
	desktopURL := flag.String("desktop-url", "", "Existing local desktop forward")
	forward := flag.Bool("forward", false, "Forward the selected box’s reported ports to local loopback")
	configure := flag.String("configure-harness", "", "Run only a harness interactive setup flow")
	attach := flag.Bool("attach", false, "Stream an existing live terminal through the local PTY")
	project := flag.String("project", "", "Project ID")
	box := flag.String("box", "", "Box ID")
	execID := flag.String("exec", "", "Concrete terminal ID")
	demo := flag.Bool("terminal-demo", false, "Run an offline PTY fixture")
	allowShell := flag.Bool("allow-shell", false, "Allow one explicitly requested new shell")
	allowManage := flag.Bool("allow-manage", false, "Allow one explicit management, approval, tool launch, or file transfer request")
	flag.Parse()
	if *configure != "" {
		if err := runHarnessSetup(*endpoint, *project, *configure); err != nil {
			fmt.Fprintf(os.Stderr, "\r\nSetup failed: %s\r\n", err)
			os.Exit(1)
		}
		fmt.Fprintln(os.Stdout, "\r\nSetup completed successfully. You can close this window.")
		return
	}
	if *irohProxy || *irohIdentity {
		if err := runIroh(*endpoint, *irohIdentity, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
			os.Exit(1)
		}
		return
	}
	if *demo {
		_ = terminalDemo()
		return
	}
	if *desktop {
		if err := runDesktop(*desktopURL, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
			os.Exit(1)
		}
		return
	}
	if *forward {
		if err := runForward(*endpoint, request{ProjectID: *project, SandboxID: *box}, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ports": []any{}, "error": err.Error()})
			os.Exit(1)
		}
		return
	}
	if *attach {
		if err := runAttach(*endpoint, request{ProjectID: *project, SandboxID: *box, ExecID: *execID}); err != nil {
			fmt.Fprintf(os.Stderr, "\r\nTerminal disconnected: %s\r\n", err)
			os.Exit(1)
		}
		return
	}
	out := response{Version: 1}
	err := runManaged(*endpoint, *allowInput, *allowShell, *allowManage, os.Stdin, &out)
	if err != nil {
		out.Error = err.Error()
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}

func run(endpoint string, allowInput bool, input io.Reader, out *response) error {
	return runAuthorized(endpoint, allowInput, false, input, out)
}
func runAuthorized(endpoint string, allowInput, allowShell bool, input io.Reader, out *response) error {
	return runManaged(endpoint, allowInput, allowShell, false, input, out)
}
func runManaged(endpoint string, allowInput, allowShell, allowManage bool, input io.Reader, out *response) error {
	var req request
	decoder := json.NewDecoder(io.LimitReader(input, 128<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		return fmt.Errorf("invalid request: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("expected one request")
	}
	b, err := newBridge(endpoint, allowInput)
	if err != nil {
		return err
	}
	b.allowShell = allowShell
	b.allowManage = allowManage
	defer b.client.CloseIdleConnections()
	duration := 15 * time.Second
	if req.Operation == "boxAction" || req.Operation == "createBox" || req.Operation == "upload" || req.Operation == "download" || (req.Operation == "auditBody" && req.LocalPath != "") {
		duration = 30 * time.Minute
		b.client.Timeout = 0
	}
	if req.Operation == "boxAction" {
		// Purge waits for confirmed removal; rename can wait for a stopped box
		// to wake. Bound the whole request by context, not a 10-second header wait.
		b.client.Transport.(*http.Transport).ResponseHeaderTimeout = 0
	}
	parent, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	ctx, cancel := context.WithTimeout(parent, duration)
	defer cancel()
	result, err := b.execute(ctx, req)
	if err != nil {
		return err
	}
	*out = result
	return nil
}

func defaultSocket() string {
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = filepath.Join(os.TempDir(), "discobox-"+strconv.Itoa(os.Getuid()))
	}
	return filepath.Join(base, "discobox", "server.sock")
}

func newBridge(endpoint string, allowInput bool) (*bridge, error) {
	u, err := url.Parse(strings.TrimSpace(endpoint))
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
			path = defaultSocket()
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
		return nil, errors.New("this build supports unix:// and existing http:// or https:// endpoints; Iroh support is not yet implemented")
	}
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirects are not accepted") },
	}
	return &bridge{client: client, base: base, allowInput: allowInput}, nil
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func validID(id string) error {
	if len(id) > 256 || !identifier.MatchString(id) {
		return errors.New("invalid resource identifier")
	}
	return nil
}

func route(req request, allowInput bool) (method, path string, body []byte, err error) {
	method = http.MethodGet
	if req.Operation == "defaultProject" {
		return method, "/projects/default", nil, nil
	}
	if err = validID(req.ProjectID); err != nil {
		return
	}
	project := "/projects/" + req.ProjectID
	if req.Operation == "harnesses" {
		return method, project + "/harness-configs", nil, nil
	}
	if req.Operation == "sandboxes" {
		return method, project + "/sandboxes", nil, nil
	}
	if err = validID(req.SandboxID); err != nil {
		return
	}
	base := "/api" + project + "/sandboxes/" + req.SandboxID
	switch req.Operation {
	case "execs", "services":
		return method, base + "/" + req.Operation, nil, nil
	case "screen", "input":
		if err = validID(req.ExecID); err != nil {
			return
		}
		if req.ExecID == "primary" {
			err = errors.New("select a concrete exec; virtual primary is not supported")
			return
		}
		path = base + "/execs/" + req.ExecID + "/" + req.Operation
		if req.Operation == "screen" {
			return method, path + "?scrollback=250", nil, nil
		}
		if !allowInput {
			err = errors.New("terminal input requires explicit permission")
			return
		}
		if err = validateInput(req.Input); err != nil {
			return
		}
		body, err = json.Marshal(struct {
			Input []inputPart `json:"input"`
		}{req.Input})
		return http.MethodPost, path, body, err
	default:
		return "", "", nil, errors.New("unsupported operation; lifecycle and arbitrary HTTP requests are not exposed")
	}
}

func validateInput(parts []inputPart) error {
	if len(parts) == 0 || len(parts) > 32 {
		return errors.New("input requires 1–32 parts")
	}
	for _, p := range parts {
		if (p.Text == nil) == (p.Key == nil) {
			return errors.New("each input part requires exactly one text or key")
		}
		if p.Text != nil && len(*p.Text) > 64<<10 {
			return errors.New("input text exceeds 64 KiB")
		}
		if p.Key != nil {
			key := *p.Key
			if len(key) == 3 && strings.HasPrefix(key, "C-") && key[2] >= 'a' && key[2] <= 'z' {
				continue
			}
			switch key {
			case "Enter", "Tab", "Escape", "Backspace", "Delete", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown":
			default:
				return errors.New("unsupported terminal key")
			}
		}
	}
	return nil
}

func (b *bridge) execute(ctx context.Context, req request) (response, error) {
	switch req.Operation {
	case "boxAction":
		return b.boxAction(ctx, req)
	case "deleteSecret", "approvals", "secrets", "answer", "createSecret", "ruleProposals":
		return b.approvals(ctx, req)
	case "tools", "openTool", "newAgent":
		return b.toolOperation(ctx, req)
	case "files", "upload", "download":
		return b.fileOperation(ctx, req)
	case "usageHeaders":
		return b.usageHeaders(ctx, req)
	case "usage":
		return b.usage(ctx, req)
	case "auditBody":
		return b.auditBody(ctx, req)
	case "audit":
		return b.audit(ctx, req)
	case "closeShell", "closeTerminal":
		return b.closeShell(ctx, req)
	case "createBox":
		return b.createBox(ctx, req)
	}
	if req.Operation == "newShell" {
		return b.newShell(ctx, req)
	}
	method, path, body, err := route(req, b.allowInput)
	if err != nil {
		return response{}, err
	}
	if method == http.MethodPost {
		// Fail closed on stopped boxes and cached inventory. These checks do not
		// revive an exec. The server ultimately owns the atomicity of input.
		if err := b.requireRunning(ctx, req); err != nil {
			return response{}, err
		}
	}
	return b.call(ctx, method, path, body)
}

func (b *bridge) requireRunningBox(ctx context.Context, req request) error {
	box, err := b.call(ctx, "GET", "/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID, nil)
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
func (b *bridge) requireRunning(ctx context.Context, req request) error {
	if err := b.requireRunningBox(ctx, req); err != nil {
		return err
	}
	exec, err := b.call(ctx, "GET", "/api/projects/"+req.ProjectID+"/sandboxes/"+req.SandboxID+"/execs/"+req.ExecID, nil)
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

func (b *bridge) call(ctx context.Context, method, path string, body []byte) (response, error) {
	req, err := http.NewRequestWithContext(ctx, method, b.base+path, bytes.NewReader(body))
	if err != nil {
		return response{}, err
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
		return response{}, fmt.Errorf("existing server request failed: %w", err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, maxBody+1))
	if err != nil {
		return response{}, err
	}
	if len(data) > maxBody {
		return response{}, errors.New("response exceeds 8 MiB")
	}
	return response{Version: 1, Status: res.StatusCode, Body: data}, nil
}

// Only a new shell can be created/started, in one explicit authorized request.
// There is intentionally no general exec-start operation.
func (b *bridge) newShell(ctx context.Context, req request) (response, error) {
	if !b.allowShell {
		return response{}, errors.New("opening a shell requires explicit permission")
	}
	if err := validID(req.ProjectID); err != nil {
		return response{}, err
	}
	if err := validID(req.SandboxID); err != nil {
		return response{}, err
	}
	if err := b.requireRunningBox(ctx, req); err != nil {
		return response{}, err
	}
	base := "/api/projects/" + req.ProjectID + "/sandboxes/" + req.SandboxID + "/execs"
	created, err := b.call(ctx, "POST", base+"?wait=ready", []byte(`{"shell":true,"tty":true,"cols":100,"rows":30,"env":{"TERM":"xterm-256color"}}`))
	if err != nil {
		return response{}, fmt.Errorf("shell creation may have succeeded; refresh terminals before retrying: %w", err)
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
		return response{}, err
	}
	id := record.Exec.ID
	if validID(id) != nil || id == "primary" || record.Exec.Primary {
		return response{}, errors.New("invalid new shell identity")
	}
	// Start only the shell returned by this request, never an existing terminal.
	started, err := b.call(ctx, "POST", base+"/"+id+"/start", nil)
	if err != nil {
		return response{}, fmt.Errorf("shell %s was created; refresh before retrying: %w", id, err)
	}
	if started.Status < 200 || started.Status >= 300 {
		return started, nil
	}
	return b.call(ctx, "GET", base+"/"+id, nil)
}
