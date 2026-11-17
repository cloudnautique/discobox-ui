package bridge

import (
	"context"
	"net/http"
	"testing"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func TestReaderServesOnlyReadsWithTheirOwnClientShape(t *testing.T) {
	r, err := NewReader("http://127.0.0.1:1")
	if err != nil {
		t.Fatal(err)
	}
	for name, op := range operations {
		_, deadlineErr := r.Deadline(wire.Request{Operation: name})
		_, runErr := r.Run(context.Background(), wire.Request{Operation: name})
		if op.permission != permissionRead && (deadlineErr != errReadOnly || runErr != errReadOnly) {
			t.Fatalf("%s (%s) was not refused: %v %v", name, op.permission, deadlineErr, runErr)
		}
		if op.permission == permissionRead && deadlineErr != nil {
			t.Fatalf("%s: %v", name, deadlineErr)
		}
	}
	// Concurrent reads cannot share one-shot mode's per-operation mutation:
	// a slow-header read gets its own client and transport, the base keeps
	// its whole-response timeout and header deadline.
	slow := r.bridgeFor(operations["harnessChanges"])
	plain := r.bridgeFor(operations["sandboxes"])
	if slow.client.Timeout != 0 || slow.client.Transport.(*http.Transport).ResponseHeaderTimeout != 0 {
		t.Fatal("harnessChanges kept the ordinary timeouts")
	}
	if plain != r.base || plain.client.Timeout == 0 || plain.client.Transport.(*http.Transport).ResponseHeaderTimeout == 0 {
		t.Fatal("ordinary reads lost their timeouts")
	}
	if slow.allowManage || slow.allowShell || r.base.allowManage || r.base.allowShell {
		t.Fatal("the reader holds a write permission")
	}
}
