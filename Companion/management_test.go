package main

import (
	"errors"
	"net/http"
	"reflect"
	"testing"
)

func TestHarnessConsoleIsRestrictedAndNeverStartsServer(t *testing.T) {
	args, err := harnessConsoleArgs("unix:///tmp/fixture.sock", "project")
	want := []string{"--server", "unix:///tmp/fixture.sock", "--project", "project", "--auto-start-server=false", "configure"}
	if err != nil || !reflect.DeepEqual(args, want) {
		t.Fatalf("%v %v", args, err)
	}
	for _, project := range []string{"", "../other", "a/b", "project; touch /tmp/x"} {
		if _, err := harnessConsoleArgs("unix:///tmp/fixture.sock", project); err == nil {
			t.Fatalf("accepted project %q", project)
		}
	}
	if _, err := harnessConsoleArgs("", "project"); err == nil {
		t.Fatal("accepted an empty endpoint")
	}
}

func TestCredentialDeleteIsScopedExplicitAndNotRetried(t *testing.T) {
	for _, authorized := range []bool{false, true} {
		b, _ := newBridge("http://fixture")
		b.allowManage = authorized
		calls := 0
		b.client.Transport = fakeTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "DELETE" || r.URL.Path != "/projects/p/secrets/secret" {
				t.Fatalf("%s %s", r.Method, r.URL.Path)
			}
			return nil, errors.New("ambiguous connection failure")
		})
		_, err := b.execute(t.Context(), request{Operation: "deleteSecret", ProjectID: "p", SecretID: "secret"})
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
	b, _ := newBridge("http://fixture")
	b.allowManage = true
	if _, err := b.execute(t.Context(), request{Operation: "deleteSecret", ProjectID: "p", SecretID: "../other"}); err == nil {
		t.Fatal("accepted invalid credential")
	}
}
