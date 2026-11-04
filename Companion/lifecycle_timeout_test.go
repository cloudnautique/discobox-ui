package main

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestArchiveAcknowledgementHasAShortDeadline(t *testing.T) {
	deadline := requestTimeout(request{Operation: "boxAction", Action: "archive"})
	if deadline <= 0 || deadline > time.Minute {
		t.Fatalf("archive acknowledgement can stall too long: %s", deadline)
	}
	if requestTimeout(request{Operation: "boxAction", Action: "repair"}) < 10*time.Minute {
		t.Fatal("long-running repair lost its completion budget")
	}
}

func TestStalledArchiveIsCancelledWithoutResubmission(t *testing.T) {
	attempts := 0
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
		attempts++
		if r.Method != "DELETE" {
			t.Fatalf("unexpected request: %s", r.Method)
		}
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
	defer cancel()
	_, err := b.boxAction(ctx, request{ProjectID: "p", SandboxID: "s", Action: "archive"})
	if !errors.Is(err, context.DeadlineExceeded) || attempts != 1 {
		t.Fatalf("error=%v attempts=%d", err, attempts)
	}
}
