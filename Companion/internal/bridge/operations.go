package bridge

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

// permission is the flag a parent must pass for an operation. It keeps a
// polling read from mutating by mistake; it is not an authorization boundary
// against another process running as the same user.
type permission string

const (
	permissionRead   permission = "read"
	permissionManage permission = "manage"
	permissionShell  permission = "shell"
)

type operation struct {
	permission permission
	run        func(*Bridge, context.Context, wire.Request) (wire.Response, error)
	// deadline bounds the whole request; zero means defaultDeadline.
	deadline        time.Duration
	actionDeadlines map[string]time.Duration
	// streaming bodies (transfers, creation, save-back) are bounded by the
	// deadline instead of the ordinary whole-response client timeout.
	streaming bool
	// slowHeaders waits for response headers until the deadline instead of
	// the ordinary 10 seconds (purge waits for confirmed removal).
	slowHeaders bool
}

const defaultDeadline = 15 * time.Second

func (op operation) deadlineFor(req wire.Request) time.Duration {
	if d, ok := op.actionDeadlines[req.Action]; ok {
		return d
	}
	if op.deadline == 0 {
		return defaultDeadline
	}
	return op.deadline
}

func boxLinkOperation(_ *Bridge, _ context.Context, req wire.Request) (wire.Response, error) {
	return parseBoxLink(req)
}

var (
	readOp = func(run func(*Bridge, context.Context, wire.Request) (wire.Response, error)) operation {
		return operation{permission: permissionRead, run: run}
	}
	writeOp = func(run func(*Bridge, context.Context, wire.Request) (wire.Response, error)) operation {
		return operation{permission: permissionManage, run: run}
	}
	// Long writes: archive only records an asynchronous intent.
	lifecycleOp = operation{permission: permissionManage, run: (*Bridge).boxAction, deadline: 30 * time.Minute,
		actionDeadlines: map[string]time.Duration{"archive": 30 * time.Second}, streaming: true, slowHeaders: true}
	transferOp = func(run func(*Bridge, context.Context, wire.Request) (wire.Response, error)) operation {
		return operation{permission: permissionManage, run: run, deadline: 30 * time.Minute, streaming: true}
	}
	// Save-back can spend 30 seconds acknowledging a committed OAuth handoff.
	harnessReviewOp = func(p permission) operation {
		return operation{permission: p, run: (*Bridge).harnessManagement, deadline: 90 * time.Second, streaming: true, slowHeaders: true}
	}
)

// operations is the companion's whole bounded request surface.
var operations = map[string]operation{
	"credentialRoutes": readOp(previewCredentialRoutes),
	"boxLink":          readOp(boxLinkOperation),
	"serverPeer":       readOp((*Bridge).routed),
	"defaultProject":   readOp((*Bridge).routed),
	"harnesses":        readOp((*Bridge).routed),
	"sandboxes":        readOp((*Bridge).routed),
	"execs":            readOp((*Bridge).routed),
	"services":         readOp((*Bridge).routed),
	"screen":           readOp((*Bridge).routed),
	"newShell":         {permission: permissionShell, run: (*Bridge).newShell},

	"setDefaultHarness":     writeOp((*Bridge).setDefaultHarness),
	"updateSecretLimits":    writeOp((*Bridge).credentialLimits),
	"harnessDetails":        readOp((*Bridge).harnessManagement),
	"harnessChanges":        harnessReviewOp(permissionRead),
	"saveHarnessChanges":    harnessReviewOp(permissionManage),
	"discardHarnessChanges": harnessReviewOp(permissionManage),

	"poolConfiguration": readOp((*Bridge).poolConfiguration),
	"updatePoolProxy":   writeOp((*Bridge).poolConfiguration),
	"poolResources":     readOp((*Bridge).poolOperation),
	"clearPoolCache": {permission: permissionManage, run: (*Bridge).poolOperation, deadline: 30 * time.Minute,
		streaming: true, slowHeaders: true},
	"boxAction": lifecycleOp,

	"approvalContext": readOp((*Bridge).approvals),
	"approvals":       readOp((*Bridge).approvals),
	"secrets":         readOp((*Bridge).approvals),
	"answer":          writeOp((*Bridge).approvals),
	"createSecret":    writeOp((*Bridge).approvals),
	"deleteSecret":    writeOp((*Bridge).approvals),

	"tools":    readOp((*Bridge).toolOperation),
	"openTool": writeOp((*Bridge).toolOperation),
	"newAgent": writeOp((*Bridge).toolOperation),

	"files":         readOp((*Bridge).fileOperation),
	"upload":        transferOp((*Bridge).fileOperation),
	"download":      transferOp((*Bridge).fileOperation),
	"usage":         readOp((*Bridge).usage),
	"usageHeaders":  readOp((*Bridge).usageHeaders),
	"audit":         readOp((*Bridge).audit),
	"auditBody":     readOp((*Bridge).auditBody),
	"saveAuditBody": transferOp((*Bridge).auditBody),

	"closeShell":    writeOp((*Bridge).closeShell),
	"closeTerminal": writeOp((*Bridge).closeShell),
	"createBox":     transferOp((*Bridge).createBox),
}

func (b *Bridge) allows(p permission) bool {
	switch p {
	case permissionRead:
		return true
	case permissionManage:
		return b.allowManage
	case permissionShell:
		return b.allowShell
	}
	return false
}

var permissionRefusals = map[permission]string{
	permissionManage: "this change requires explicit management permission",
	permissionShell:  "opening a shell requires explicit permission",
}

func lookupOperation(name string) (operation, error) {
	op, ok := operations[name]
	if !ok {
		return operation{}, errors.New("unsupported operation; lifecycle and arbitrary HTTP requests are not exposed")
	}
	return op, nil
}

func (b *Bridge) execute(ctx context.Context, req wire.Request) (wire.Response, error) {
	op, err := lookupOperation(req.Operation)
	if err != nil {
		return wire.Response{}, err
	}
	return b.dispatch(ctx, op, req)
}

// dispatch checks op's permission flag, then runs it.
func (b *Bridge) dispatch(ctx context.Context, op operation, req wire.Request) (wire.Response, error) {
	if !b.allows(op.permission) {
		return wire.Response{}, errors.New(permissionRefusals[op.permission])
	}
	return op.run(b, ctx, req)
}

// configure applies the operation's deadline to this process's one client.
func (op operation) configure(client *http.Client) {
	if op.streaming {
		client.Timeout = 0
	}
	if op.slowHeaders {
		client.Transport.(*http.Transport).ResponseHeaderTimeout = 0
	}
}
