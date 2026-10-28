package main

import (
	"errors"
	"os"
	"strings"

	"github.com/discobox-ai/discobox/cli/internal/cli"
)

// Reuse the upstream configure lifecycle, including callback port forwarding,
// provisioning, terminal attachment, and exit-status-checked commit. No arbitrary
// CLI arguments are accepted and server auto-start is always disabled.
func harnessSetupArgs(endpoint, project, harness string) ([]string, error) {
	if strings.HasPrefix(harness, "-") || endpoint == "" || validID(project) != nil || validID(harness) != nil {
		return nil, errors.New("invalid harness setup destination")
	}
	return []string{"--server", endpoint, "--project", project, "--auto-start-server=false", "admin", "harness", "configure", harness}, nil
}

func runHarnessSetup(endpoint, project, harness string) error {
	args, err := harnessSetupArgs(endpoint, project, harness)
	if err != nil {
		return err
	}
	cmd := cli.NewRootCommand()
	cmd.SetArgs(args)
	cmd.SetIn(os.Stdin)
	cmd.SetOut(os.Stdout)
	cmd.SetErr(os.Stderr)
	return cmd.Execute()
}
