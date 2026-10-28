package main

import (
	"errors"
	"github.com/discobox-ai/discobox/cli/internal/cli"
	"net/http"
	"reflect"
	"testing"
)

func TestHarnessSetupIsRestrictedAndNeverStartsServer(t *testing.T) {
	args, err := harnessSetupArgs("unix:///tmp/fixture.sock", "project", "harness")
	want := []string{"--server", "unix:///tmp/fixture.sock", "--project", "project", "--auto-start-server=false", "admin", "harness", "configure", "harness"}
	if err != nil || !reflect.DeepEqual(args, want) {
		t.Fatalf("%v %v", args, err)
	}
	for _, id := range []string{"", "../other", "--help", "harness; touch /tmp/x"} {
		// Flag-like IDs are accepted by validID, but must never reach the CLI parser.
		if _, err := harnessSetupArgs("unix:///tmp/fixture.sock", "project", id); err == nil {
			t.Fatalf("accepted %q", id)
		}
	}
}

func TestHarnessSetupResolvesToUpstreamConfigureCommand(t *testing.T) {
	cmd := cli.NewRootCommand()
	found, remaining, err := cmd.Find([]string{"admin", "harness", "configure", "fixture"})
	if err != nil || found.Name() != "configure" || !reflect.DeepEqual(remaining, []string{"fixture"}) {
		t.Fatalf("wrong setup command: %v %v %v", found, remaining, err)
	}
}

func TestCredentialDeleteIsScopedExplicitAndNotRetried(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		b, _ := newBridge("http://fixture", false)
		b.allowManage = authorized
		calls := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "DELETE" || r.URL.Path != "/projects/p/secrets/secret" {
				t.Fatalf("%s %s", r.Method, r.URL.Path)
			}
			return nil, errors.New("ambiguous connection failure")
		})
		_, err := b.execute(t.Context(), request{Operation: "deleteSecret", ProjectID: "p", RequestID: "secret"})
		if err == nil {
			t.Fatal("expected refusal/failure")
		}
		expected := 0
		if authorized {
			expected = 1
		}
		if calls != expected {
			t.Fatalf("calls %d", calls)
		}
	}
	b, _ := newBridge("http://fixture", false)
	b.allowManage = true
	if _, err := b.execute(t.Context(), request{Operation: "deleteSecret", ProjectID: "p", RequestID: "../other"}); err == nil {
		t.Fatal("accepted invalid credential")
	}
}
