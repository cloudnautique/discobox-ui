// Package upstream is the companion's only door into the Discobox CLI's
// internal packages (github.com/discobox-ai/discobox/cli/internal/...).
//
// Go lets this module import them only because its path,
// github.com/discobox-ai/discobox/cli/desktopbridge, sits beneath upstream's
// cli/ tree. Those packages carry no compatibility promise, so every use is
// confined here as aliases and thin forwarders: an upstream change breaks this
// one package instead of handlers across the companion, and nothing is copied.
//
// The package can be deleted once upstream promotes, under its public pkg/
// tree:
//   - portforward: Forwarder, New, Options, Target, Network (TCP/UDP),
//     Event/Kind (BindFailed, DialFailed) and DefaultDialHost;
//   - from sandboxcreate: ParseSource, BuildPromptSandboxBody with
//     PromptOptions and IncludeDirty, DeliverSource with DeliveryOptions and
//     GitCredentials, and ProvisionStatus;
//   - a way to run the `configure` console command (today only reachable
//     through cli.NewRootCommand).
package upstream

import (
	"context"
	"io"

	apimodel "github.com/discobox-ai/discobox/api/model"
	"github.com/discobox-ai/discobox/cli/internal/cli"
	"github.com/discobox-ai/discobox/cli/internal/portforward"
	"github.com/discobox-ai/discobox/cli/internal/sandboxcreate"
	"github.com/discobox-ai/discobox/pkg/sourceref"
)

// Port forwarding: cli/internal/portforward.
type (
	PortForwarder      = portforward.Forwarder
	PortForwardOptions = portforward.Options
	PortTarget         = portforward.Target
	PortNetwork        = portforward.Network
	PortEvent          = portforward.Event
)

const (
	TCP             = portforward.TCP
	UDP             = portforward.UDP
	DefaultDialHost = portforward.DefaultDialHost
	PortBindFailed  = portforward.BindFailed
	PortDialFailed  = portforward.DialFailed
)

// NewPortForwarder starts a forwarder owning local listeners for its targets.
func NewPortForwarder(ctx context.Context, opts PortForwardOptions) *PortForwarder {
	return portforward.New(ctx, opts)
}

// Box creation and source delivery: cli/internal/sandboxcreate.
type (
	PromptOptions   = sandboxcreate.PromptOptions
	LocalSources    = sandboxcreate.LocalSources
	DeliveryOptions = sandboxcreate.DeliveryOptions
	ProvisionStep   = sandboxcreate.Step
)

const (
	IncludeDirtyNever   = sandboxcreate.IncludeDirtyNever
	GitCredentialsLocal = sandboxcreate.GitCredentialsLocal
)

// ParseSource parses a create source the way `discobox create` does.
func ParseSource(source string) (sourceref.Ref, error) { return sandboxcreate.ParseSource(source) }

// BuildPromptSandboxBody builds a create request and its local sources.
func BuildPromptSandboxBody(ctx context.Context, opts PromptOptions) (*apimodel.CreateSandboxBody, *LocalSources, error) {
	return sandboxcreate.BuildPromptSandboxBody(ctx, opts)
}

// DeliverSource pushes local sources into a newly created box. It is a
// variable, not a forwarder, because its client parameter is an unexported
// upstream interface this package cannot name without restating it.
var DeliverSource = sandboxcreate.DeliverSource

// ProvisionStatus is the CLI's one-word preparation status for a box.
func ProvisionStatus(sandbox *apimodel.Sandbox) ProvisionStep {
	return sandboxcreate.ProvisionStatus(sandbox)
}

// RunCLI runs the upstream CLI root command in-process with args.
func RunCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	cmd := cli.NewRootCommand()
	cmd.SetArgs(args)
	cmd.SetIn(stdin)
	cmd.SetOut(stdout)
	cmd.SetErr(stderr)
	return cmd.Execute()
}
