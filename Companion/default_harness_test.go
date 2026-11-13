package main

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
)

func TestDefaultHarnessRequiresExplicitManagementAndValidDestination(t *testing.T) {
	for _, req := range []request{
		{Operation: "setDefaultHarness", ProjectID: "p", HarnessID: "h"},
		{Operation: "setDefaultHarness", ProjectID: "../other", HarnessID: "h"},
		{Operation: "setDefaultHarness", ProjectID: "p", HarnessID: "../other"},
	} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = req.ProjectID != "p" || req.HarnessID != "h"
		b.client.Transport = fakeTransport(func(*http.Request) (*http.Response, error) { t.Fatal("unexpected network request"); return nil, nil })
		if _, err := b.execute(context.Background(), req); err == nil {
			t.Fatal("invalid or unauthorized mutation accepted")
		}
	}
}

func TestDefaultHarnessUsesProjectEndpointAndNeverRetriesWrites(t *testing.T) {
	for _, fail := range []bool{false, true} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = true
		writes := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			writes++
			if r.Method != http.MethodPut || r.URL.Path != "/projects/p/harness-configs/h/default" {
				t.Fatalf("unexpected destination %s %s", r.Method, r.URL.Path)
			}
			if fail {
				return nil, errors.New("connection lost")
			}
			return reply(`{"id":"p","name":"Project","defaultHarnessConfigId":"h"}`), nil
		})
		result, err := b.execute(context.Background(), request{Operation: "setDefaultHarness", ProjectID: "p", HarnessID: "h"})
		if writes != 1 {
			t.Fatalf("writes = %d", writes)
		}
		if fail {
			if err == nil || !strings.Contains(err.Error(), "refresh before retrying") {
				t.Fatalf("missing ambiguous outcome: %v", err)
			}
		} else if err != nil || result.Status != 200 {
			t.Fatalf("failed default update: %v", err)
		}
	}
}
