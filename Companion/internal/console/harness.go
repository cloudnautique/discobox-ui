// Package console runs the --harness-console mode: upstream's own console on
// its harnesses screen, in-process, against the app's resolved endpoint with
// server auto-start disabled.
package console

import (
	"errors"
	"os"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/upstream"
)

// harnessConsoleArgs opens upstream's console on its harnesses screen
// (`discobox configure`, which takes no arguments) for one project. Upstream
// manages saved harness files there instead of in a separate configure
// sandbox. No arbitrary CLI arguments are accepted.
func harnessConsoleArgs(endpoint, project string) ([]string, error) {
	if endpoint == "" || bridge.ValidID(project) != nil {
		return nil, errors.New("invalid harness console destination")
	}
	return []string{"--server", bridge.ResolveEndpoint(endpoint), "--project", project, "--auto-start-server=false", "configure"}, nil
}

// RunHarnesses opens the console on project's harnesses screen.
func RunHarnesses(endpoint, project string) error {
	args, err := harnessConsoleArgs(endpoint, project)
	if err != nil {
		return err
	}
	return upstream.RunCLI(args, os.Stdin, os.Stdout, os.Stderr)
}
