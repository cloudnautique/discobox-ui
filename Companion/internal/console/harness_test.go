package console

import (
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

func TestHarnessConsoleSharesTheEndpointResolver(t *testing.T) {
	t.Setenv("DISCOBOX_SERVER_ADDRESS", "http://127.0.0.1:12345")
	args, err := harnessConsoleArgs("unix://", "p")
	if err != nil || args[1] != "http://127.0.0.1:12345" {
		t.Fatalf("console doesn't share resolver %v %v", args, err)
	}
}
