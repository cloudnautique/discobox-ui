package upstream

import (
	"testing"

	"github.com/discobox-ai/discobox/cli/internal/cli"
)

// The harness console runs upstream's argument-free `configure` command.
func TestConfigureCommandResolvesWithoutArguments(t *testing.T) {
	found, remaining, err := cli.NewRootCommand().Find([]string{"configure"})
	if err != nil || found.Name() != "configure" || len(remaining) != 0 {
		t.Fatalf("wrong console command: %v %v %v", found, remaining, err)
	}
	if found.Args == nil || found.Args(found, []string{"harness"}) == nil {
		t.Fatal("upstream configure now accepts arguments; revisit --harness-console")
	}
}
