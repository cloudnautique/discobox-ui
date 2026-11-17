package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

type protocolManifest struct {
	Version    int                   `json:"version"`
	Operations map[string]permission `json:"operations"`
}

func currentManifest() protocolManifest {
	manifest := protocolManifest{Version: wire.ProtocolVersion, Operations: map[string]permission{}}
	for name, op := range operations {
		manifest.Operations[name] = op.permission
	}
	return manifest
}

// manifestPath is Companion/protocol.json, relative to this package; the
// Swift tests read the same file.
const manifestPath = "../../protocol.json"

// protocol.json is the contract the Swift client is tested against. Regenerate
// it with UPDATE_PROTOCOL=1 go test ./internal/bridge -run TestProtocolManifest
// after changing the registry, and update BridgeRequest.Operation to match.
func TestProtocolManifestMatchesRegistry(t *testing.T) {
	want, err := json.MarshalIndent(currentManifest(), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	want = append(want, '\n')
	if os.Getenv("UPDATE_PROTOCOL") == "1" {
		if err := os.WriteFile(manifestPath, want, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("protocol.json is stale; run UPDATE_PROTOCOL=1 go test ./internal/bridge -run TestProtocolManifest\nwant:\n%s", want)
	}
}

func TestEveryOperationIsDispatchedAndPermissionChecked(t *testing.T) {
	names := make([]string, 0, len(operations))
	for name := range operations {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		op := operations[name]
		if op.run == nil {
			t.Fatalf("%s has no handler", name)
		}
		switch op.permission {
		case permissionRead:
			continue
		case permissionManage, permissionShell:
		default:
			t.Fatalf("%s has unknown permission %q", name, op.permission)
		}
		// Without its flag, a non-read operation is refused before any I/O.
		b := &Bridge{}
		_, err := b.execute(context.Background(), wire.Request{Operation: name, ProjectID: "p", SandboxID: "s", ExecID: "e"})
		if err == nil || err.Error() != permissionRefusals[op.permission] {
			t.Fatalf("%s without %s permission: %v", name, op.permission, err)
		}
	}
	if _, err := (&Bridge{allowManage: true}).execute(context.Background(), wire.Request{Operation: "ruleProposals"}); err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("unknown operation was dispatched: %v", err)
	}
}

func TestDeadlinesComeFromTheRegistry(t *testing.T) {
	for name, want := range map[string]struct {
		action          string
		deadline        float64
		streaming, slow bool
	}{
		"sandboxes":          {deadline: 15},
		"harnessDetails":     {deadline: 15},
		"harnessChanges":     {deadline: 90, streaming: true, slow: true},
		"saveHarnessChanges": {deadline: 90, streaming: true, slow: true},
		"boxAction":          {action: "repair", deadline: 1800, streaming: true, slow: true},
		"clearPoolCache":     {deadline: 1800, streaming: true, slow: true},
		"createBox":          {deadline: 1800, streaming: true},
		"upload":             {deadline: 1800, streaming: true},
		"saveAuditBody":      {deadline: 1800, streaming: true},
		"auditBody":          {deadline: 15},
	} {
		op := operations[name]
		if got := op.deadlineFor(wire.Request{Operation: name, Action: want.action}).Seconds(); got != want.deadline || op.streaming != want.streaming || op.slowHeaders != want.slow {
			t.Fatalf("%s: deadline %v streaming %v slow headers %v", name, got, op.streaming, op.slowHeaders)
		}
	}
	// Archive records an asynchronous intent, without waiting for removal.
	if got := operations["boxAction"].deadlineFor(wire.Request{Action: "archive"}).Seconds(); got != 30 {
		t.Fatalf("archive deadline %v", got)
	}
}
