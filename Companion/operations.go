package main

import (
	"context"
	"errors"
	"net/http"
	"time"
)

// protocolVersion is the wire version of a bounded request/response. The
// operation names, their permission classes and this version are published in
// protocol.json, which the Go and Swift tests both check against.
const protocolVersion = 2

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
	run        func(*bridge, context.Context, request) (response, error)
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

func (op operation) deadlineFor(req request) time.Duration {
	if d, ok := op.actionDeadlines[req.Action]; ok {
		return d
	}
	if op.deadline == 0 {
		return defaultDeadline
	}
	return op.deadline
}

func boxLinkOperation(_ *bridge, _ context.Context, req request) (response, error) {
	return parseBoxLink(req)
}

var (
	readOp = func(run func(*bridge, context.Context, request) (response, error)) operation {
		return operation{permission: permissionRead, run: run}
	}
	writeOp = func(run func(*bridge, context.Context, request) (response, error)) operation {
		return operation{permission: permissionManage, run: run}
	}
	// Long writes: archive only records an asynchronous intent.
	lifecycleOp = operation{permission: permissionManage, run: (*bridge).boxAction, deadline: 30 * time.Minute,
		actionDeadlines: map[string]time.Duration{"archive": 30 * time.Second}, streaming: true, slowHeaders: true}
	transferOp = func(run func(*bridge, context.Context, request) (response, error)) operation {
		return operation{permission: permissionManage, run: run, deadline: 30 * time.Minute, streaming: true}
	}
	// Save-back can spend 30 seconds acknowledging a committed OAuth handoff.
	harnessReviewOp = func(p permission) operation {
		return operation{permission: p, run: (*bridge).harnessManagement, deadline: 90 * time.Second, streaming: true, slowHeaders: true}
	}
)

// operations is the companion's whole bounded request surface.
var operations = map[string]operation{
	"boxLink":        readOp(boxLinkOperation),
	"serverPeer":     readOp((*bridge).routed),
	"defaultProject": readOp((*bridge).routed),
	"harnesses":      readOp((*bridge).routed),
	"sandboxes":      readOp((*bridge).routed),
	"execs":          readOp((*bridge).routed),
	"services":       readOp((*bridge).routed),
	"screen":         readOp((*bridge).routed),
	"newShell":       {permission: permissionShell, run: (*bridge).newShell},

	"setDefaultHarness":     writeOp((*bridge).setDefaultHarness),
	"updateSecretLimits":    writeOp((*bridge).credentialLimits),
	"harnessDetails":        readOp((*bridge).harnessManagement),
	"harnessChanges":        harnessReviewOp(permissionRead),
	"saveHarnessChanges":    harnessReviewOp(permissionManage),
	"discardHarnessChanges": harnessReviewOp(permissionManage),

	"poolConfiguration": readOp((*bridge).poolConfiguration),
	"updatePoolProxy":   writeOp((*bridge).poolConfiguration),
	"poolResources":     readOp((*bridge).poolOperation),
	"clearPoolCache": {permission: permissionManage, run: (*bridge).poolOperation, deadline: 30 * time.Minute,
		streaming: true, slowHeaders: true},
	"boxAction": lifecycleOp,

	"approvalContext": readOp((*bridge).approvals),
	"approvals":       readOp((*bridge).approvals),
	"secrets":         readOp((*bridge).approvals),
	"answer":          writeOp((*bridge).approvals),
	"createSecret":    writeOp((*bridge).approvals),
	"deleteSecret":    writeOp((*bridge).approvals),

	"tools":    readOp((*bridge).toolOperation),
	"openTool": writeOp((*bridge).toolOperation),
	"newAgent": writeOp((*bridge).toolOperation),

	"files":         readOp((*bridge).fileOperation),
	"upload":        transferOp((*bridge).fileOperation),
	"download":      transferOp((*bridge).fileOperation),
	"usage":         readOp((*bridge).usage),
	"usageHeaders":  readOp((*bridge).usageHeaders),
	"audit":         readOp((*bridge).audit),
	"auditBody":     readOp((*bridge).auditBody),
	"saveAuditBody": transferOp((*bridge).auditBody),

	"closeShell":    writeOp((*bridge).closeShell),
	"closeTerminal": writeOp((*bridge).closeShell),
	"createBox":     transferOp((*bridge).createBox),
}

func (b *bridge) allows(p permission) bool {
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

func (b *bridge) execute(ctx context.Context, req request) (response, error) {
	op, err := lookupOperation(req.Operation)
	if err != nil {
		return response{}, err
	}
	return b.dispatch(ctx, op, req)
}

// dispatch checks op's permission flag, then runs it.
func (b *bridge) dispatch(ctx context.Context, op operation, req request) (response, error) {
	if !b.allows(op.permission) {
		return response{}, errors.New(permissionRefusals[op.permission])
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
