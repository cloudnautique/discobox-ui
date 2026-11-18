// discobox-desktop-bridge is a bounded, unprivileged client. It never runs the
// general-purpose Discobox CLI or launches a backend. Explicit repository delivery uses a
// temporary loopback Git proxy scoped to the newly created box.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/bridge"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/console"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/desktop"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/diagnostics"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/events"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/forward"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/iroh"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/terminal"
	"github.com/discobox-ai/discobox/cli/desktopbridge/internal/wire"
)

func main() {
	irohProxy := flag.Bool("iroh-proxy", false, "Keep an authenticated Iroh connection behind a private socket")
	irohIdentity := flag.Bool("iroh-identity", false, "Print the public identity supplied over stdin")
	endpoint := flag.String("endpoint", "unix://", "An existing Discobox endpoint")
	desktopMode := flag.Bool("desktop", false, "Embed the existing desktop viewer with a native clipboard bridge")
	desktopURL := flag.String("desktop-url", "", "Existing local desktop forward")
	eventMode := flag.Bool("events", false, "Subscribe to project events")
	afterEvent := flag.Int64("after-event-id", -1, "Last applied project event")
	forwardMode := flag.Bool("forward", false, "Forward the selected box’s reported ports to local loopback")
	harnessConsole := flag.Bool("harness-console", false, "Open the console's harness screen for --project")
	noAutoReconnect := flag.Bool("no-auto-reconnect", false, "Stop after a terminal transport loss")
	attachMode := flag.Bool("attach", false, "Stream an existing live terminal through the local PTY")
	attachStatus := flag.String("attach-status", "", "Private FIFO for terminal connection state")
	project := flag.String("project", "", "Project ID")
	box := flag.String("box", "", "Box ID")
	execID := flag.String("exec", "", "Concrete terminal ID")
	demo := flag.Bool("terminal-demo", false, "Run an offline PTY fixture")
	allowShell := flag.Bool("allow-shell", false, "Allow one explicitly requested new shell")
	allowManage := flag.Bool("allow-manage", false, "Allow one explicit management, approval, tool launch, or file transfer request")
	diagnosticConnection := flag.String("diagnostic-connection", "", "Opaque UI connection generation for diagnostics")
	flag.Parse()
	finishDiagnostics := func() {}
	if *attachMode || *irohProxy || *eventMode {
		component := "terminal"
		if *irohProxy {
			component = "iroh_proxy"
		} else if *eventMode {
			component = "project_events"
		}
		finishDiagnostics = diagnostics.Start(component, *endpoint, *diagnosticConnection, wire.Request{ProjectID: *project, SandboxID: *box, ExecID: *execID})
	}
	defer finishDiagnostics()
	if *eventMode {
		if policy := os.Getenv("DISCOBOX_UI_AUTOMATIC_GUEST_READS"); policy == "paused" || policy == "enabled" {
			diagnostics.Emit(diagnostics.Event{Event: "launch_guest_read_policy", Reason: policy})
		}
		if *afterEvent >= 0 {
			diagnostics.Emit(diagnostics.Event{Event: "event_resume"})
		}
		if err := events.Run(*endpoint, *project, *afterEvent, os.Stdin, os.Stdout); err != nil {
			diagnostics.Emit(diagnostics.Event{Event: "event_stream_ended", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		return
	}
	if *harnessConsole {
		if err := console.RunHarnesses(*endpoint, *project); err != nil {
			fmt.Fprintf(os.Stderr, "\r\nSetup failed: %s\r\n", err)
			diagnostics.Emit(diagnostics.Event{Event: "helper_failed", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		fmt.Fprintln(os.Stdout, "\r\nSetup completed successfully. You can close this window.")
		return
	}
	if *irohProxy || *irohIdentity {
		if err := iroh.Run(*endpoint, *irohIdentity, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error(), "errorKind": wire.ErrorKind(err)})
			diagnostics.Emit(diagnostics.Event{Event: "helper_failed", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		return
	}
	if *demo {
		_ = terminal.Demo()
		return
	}
	if *desktopMode {
		if err := desktop.Run(*desktopURL, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
			diagnostics.Emit(diagnostics.Event{Event: "helper_failed", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		return
	}
	if *forwardMode {
		if err := forward.Run(*endpoint, wire.Request{ProjectID: *project, SandboxID: *box}, os.Stdin, os.Stdout); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ports": []any{}, "error": err.Error()})
			diagnostics.Emit(diagnostics.Event{Event: "helper_failed", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		return
	}
	if *attachMode {
		if err := terminal.Attach(*endpoint, wire.Request{ProjectID: *project, SandboxID: *box, ExecID: *execID}, *attachStatus, !*noAutoReconnect); err != nil {
			if *attachStatus == "" {
				fmt.Fprintf(os.Stderr, "\r\nTerminal disconnected: %s\r\n", err)
			}
			diagnostics.Emit(diagnostics.Event{Event: "helper_failed", Reason: diagnostics.Reason(err)})
			finishDiagnostics()
			os.Exit(1)
		}
		return
	}
	out := wire.Response{Version: wire.ProtocolVersion}
	err := bridge.RunManaged(*endpoint, *allowShell, *allowManage, os.Stdin, &out)
	if err != nil {
		out.Error = err.Error()
		out.ErrorKind = wire.ErrorKind(err)
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}
