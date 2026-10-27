# Discobox for macOS

A native SwiftUI client for **existing Discobox servers and boxes**. The backend
remains the source of truth; boxes stay usable through the CLI and other clients.

This build provides:

- Automatically tries the default local Unix socket on launch, with a connecting screen and manual connection form on failure. Custom Unix socket and HTTP/S endpoints are also supported.
- The server's default project, searchable box lists, running/attention/archive filters, and an inspector. Project selection is internal and has no UI.
- Repository-grouped sidebar with harness, branch, and server-reported lifecycle state. Right-click a box or use its toolbar action menu to start, stop, rename, archive, restore, upgrade, or repair. Swipe left to reveal Archive; Archived offers Restore and confirmed permanent Purge.
- Embedded Ghostty terminals with direct keyboard input, selection, copy/paste, and resize. Shift-Enter and Ctrl-Enter use the Discobox TUI’s newline mappings (Escape + Return and line feed).
- Resumable terminal streams; sessions survive switching boxes and tabs.
- Read-only saved screens for stopped boxes and ended terminals.
- Declared services plus discovered ports and Desktop. Desktop opens in a native WebKit window; other web ports open in the browser through loopback-only TCP forwards; TCP/UDP ports have copyable local addresses. Port collisions are remapped automatically.
- Configurable command leader and sequences in **Discobox → Settings → Keybindings**.
- Explicit Open Shell for a running box; never invoked by selecting a box.
- Audit with live polling, source filters, search, and record details.
- New Box with a configured harness, optional remote Git repository, and multiline starting prompt.
- Close controls for secondary terminals, with confirmation; the primary harness is protected.
- Automatic credential/trust inbox, red ! badges, duration and policy review, refresh, delegation and explicit auto-approval rules.
- Changes via discobox-review, declared sandbox tools, and additional agent sessions.
- Workspace files with streamed drag/drop, upload/download, progress, cancellation, and conflict handling.
- An isolated demo workspace that never contacts a server.

Selecting a live terminal attaches to its shared stream. Typing goes straight to
that terminal; there is no input checkbox. Iroh/Discobot authentication remains future work.
The implementation sequence is in [PLAN.md](PLAN.md).

## Build

Requires macOS 14+, Xcode with Swift 6 and the Metal Toolchain component,
Go 1.27.1+, and Zig 0.14.1 to build the pinned Ghostty v1.2.3 SDK. The native
architecture SDK must be built before SwiftPM can resolve the package. Dependency
source and build caches stay in `.build`. The companion reuses a separate checkout of the
Discobox streaming packages through a local Go module replacement.

The backend checkout is ignored by this repository. Before the first build,
clone the upstream source at the revision used by this client (requires access
to that repository). This only checks out source; it does not run a backend:

```sh
git clone https://github.com/discobox-ai/discobox.git discobox
git -C discobox checkout d61a7f405389fcc0dda68c5689397aec3a085d9e
```

```sh
bash scripts/build-ghostty-sdk.sh
bash scripts/build-app.sh
```

The result is `dist/Discobox.app`. The build script never launches the app or
Discobox. Open the app yourself and choose **Explore demo workspace**, or connect
to an existing server. For a demo-only launch:

```sh
open dist/Discobox.app --args --demo
```

`unix://` resolves the default socket using the same runtime-directory convention
as the CLI. A specific socket can be entered as `unix:///absolute/path/server.sock`.
Use HTTP/S only if the server already listens there; no listener is added or
backend configuration changed. With required authentication, a server may refuse
this build because Iroh and Discobot assertions are not implemented yet.

The bundle is **ad-hoc signed for local development**, not Developer ID signed or
notarized. It is not an App Store sandbox build. Distribution signing and helper
packaging need their own release work.

For Xcode development, open `Package.swift` and run the executable target. Build
the companion first, then set `DISCOBOX_DESKTOP_BRIDGE` in the run scheme to the
absolute path of `.build/discobox-desktop-bridge`, and set
`GHOSTTY_RESOURCES_DIR` to the SDK's `Resources/ghostty` directory. The packaged
app finds both its companion and resources inside the bundle.

## Workspace commands

Default leader: **Ctrl-A**. Change it to Ctrl-D (or another Control-letter) in
**Discobox → Settings → Keybindings**, then choose **Save Keybindings**. Existing
terminal sessions pick up the change immediately. The command button, **⌘H**, and the Workspace menu expose help/actions. Keyboard
configuration lives only in Settings. ⌘H replaces the usual Hide shortcut; Hide
remains available in the app menu.

| After the leader | Command |
| --- | --- |
| `a` or `0` | Agent / first terminal |
| `h` / `l`, left / right | Previous / next terminal |
| `1`–`9` | Numbered terminal tab |
| `s` | Open a new shell |
| `S`, then `0` | Services |
| `A` (Shift-A) | Audit trail |
| `d` | Box chooser (GUI equivalent of leaving the pane) |
| `[` / `]` | Previous / next box (GUI additions) |
| `z` | Focus mode: hide/show the box sidebar |
| `r` | Refresh (GUI addition) |
| `?` | Command list |
| `q` | Disconnect the GUI, leaving remote sessions running |

Press the leader twice to send its literal control character to the terminal.
Escape cancels; unfinished sequences expire after three seconds. Unknown commands
are consumed and explained rather than typed into the remote prompt. Keybindings
are scoped to the workspace window and do not intercept editable text fields.
Conflicting sequences cannot be saved. Uppercase suffixes mean Shift-letter.
Tools and additional agents are available in the workspace. Lifecycle actions are
available from each box’s context menu and the toolbar action menu.

## Verification

```sh
bash scripts/test.sh
# Offline AppKit/Ghostty/PTY integration check; exits with a pass/fail result:
dist/Discobox.app/Contents/MacOS/DiscoboxDesktop --terminal-smoke
dist/Discobox.app/Contents/MacOS/DiscoboxDesktop --command-smoke
# Panel rendering without keyboard activation:
dist/Discobox.app/Contents/MacOS/DiscoboxDesktop --feature-smoke
```

Tests use fixture clients, temporary fixture executables, and injected Go HTTP
transports and temporary loopback WebSocket fixture servers. They do not connect to your server or execute the Discobox CLI.

## Operational boundaries

Opening the app is disconnected. Reading box lists, exec/service inventories,
and screens uses only the backend's observational routes. Logs, files, and resource
GETs are deliberately excluded from polling: some of those reads can wake boxes.
No existing-box start, stop, restart, delete, repair, or shutdown action is exposed.
Creation and shell closure each require an explicit authorized action.
Open Shell has a separate opt-in operation that creates and starts only the new
shell returned by that request, after checking that the box is running.

Selecting a live terminal opens an interactive attach. It counts as activity,
resizes the shared terminal, and sends your keystrokes; other clients remain
usable and see the same session. Switching away retains the local session until
disconnect or app exit. Closing the GUI closes only its local helper and stream:
it sends no remote signal or close-input frame.

The helper checks for a live running box and concrete terminal before each
attach. It refuses stopped, cached, exited, and virtual-primary targets. The
backend can still revive a terminal that exits between the check and attach;
an atomic “attach only if still running” guarantee requires a backend contract
change. Reconnect reuses the backend's positioned input protocol to avoid
replaying acknowledged input. Failed live-state checks end reconnection; use
Reconnect after recovery.

All files for this client live outside `./discobox`; its source and running
instance are not modified by this project.


## Workspace actions

- Pull down on the box list at its top to refresh, or use ⌘R. Reconnect is beside
  the connection indicator at bottom right and reconnects only the GUI client.
- Click a shell tab's × to close it. Confirmation ends that shell's remote process;
  it does not stop the box. The primary harness cannot be closed this way.
- Click + beside the box-list filter or choose Workspace → New Box. Choose a
  configured harness and optionally a remote Git URL or OWNER/REPO. The server's
  default pool is used. Repositories use Discobox's existing source preparation
  and cache-delivery code, including local Git credentials. No CLI command or
  SSH-config synchronization is run. For socket endpoints Git uses a temporary
  loopback proxy restricted to Git routes on the newly created box. Failures after
  creation identify that box; never blindly repeat Create after an ambiguous error.
- Audit polls only while its view is open and Follow is enabled. It reads HTTP,
  credential verdicts, secret refreshes, harness hooks, and exec events, reporting
  missing sources/pools explicitly. Load older pages with the footer action;
  Follow reads forward (HTTP uses per-pool row cursors). The view retains up to
  50,000 rows. Timestamp-only trails can stall at a page full of identical times;
  the UI reports that limit rather than skipping rows. Details are bounded and
  HTTP request/response bodies have explicit, on-demand 1 MiB previews, with
  truncation reported. Export saves the full available recording without replacing existing files.

Creation/source delivery has fixture coverage but has not been exercised against
an operator server. Quit cancels outstanding companion requests and their Git
work; it never deletes a partially created box. The operator instance remains
excluded from development tests.

### Split workspace

With **Keep Agent Visible** enabled (the default), Agent has one header on the
left and shells, Audit, Services, and Files have their own tab strip in the right
pane. Use **+** to open a tab. No extra workspace-wide tab row or repeated pane
title is shown. The selected tool appears beside the agent in a resizable split. The Layout menu switches between
below/beside arrangements or a single full-size tab. Tabs also offer these options
in their context menus. A thin accent line identifies the focused pane.

**⌘{ / ⌘}** (Command-Shift-brackets) select the previous/next tab.
**⌘[ / ⌘]** move keyboard focus between panes within the selected tab.
When the agent is pinned, tab cycling wraps through tool tabs only.
**⌘N** opens New Box and **⌘K** opens the box switcher. In the switcher,
type to search box names, harnesses, and repositories; ↑/↓ select a result,
Return opens it, and Escape cancels. Space-separated search terms can match
different fields (for example, a harness name plus a repository name). These shortcuts,
including tab/pane navigation and Help, can be changed or disabled under
Settings → Keybindings → App Shortcuts, separately from leader bindings.
Audit focuses Search on entry and when keyboard focus returns to its pane;
selecting an event initially gives its message details one-third of the list/detail
area, with a draggable divider.
Tab selection and layout are remembered per box for the current connection.
Switching tabs retains terminal sessions; a shell tab's × still asks before
terminating its process. Closing an Audit/Services/Files tab only hides that view.
Help remains available through ⌘H and the Help menu.
The app icon is compiled from `discobox/assets/brand/favicon.png`.

### Requests, review, and files

The approval inbox polls every two seconds independently of box selection. Red
`!` buttons on box rows and the harness header open the approval form directly
when one request is waiting; multiple requests use a chooser. The action row is
Later, then Approve and Deny on the right. Approve submits directly; Return is
assigned to Deny and Escape to Later.
Approval notifications and leader hints use existing header/footer space so
they do not resize the harness while it is drawing its input prompt. Grants
show their policy and explicit lifetime; trust approvals show certificate pins;
refresh accepts a concealed replacement value. Advanced approval can create a
repository-scoped rule or explicitly alter a credential's restrictions as part
of the explicit Approve action. New credentials currently support token entry; OAuth sign-in
and executing local refresh commands remain CLI workflows. No reply is retried
automatically after an ambiguous failure. A server-side owner override is not
invented by this client; its scope is still being decided.

Use the harness + menu for Changes, Tools, additional agents, or Files. Default
leader shortcuts: `v` Changes, `o` Tools, `f` Files, `!` Requests. Changes runs the
box's declared diff tool; the Tools sheet can review explicit base/head refs
already present in that repository. Host-launched tools are not executed by the
GUI. Existing running tool sessions are reused; the primary harness stays visible.

Files opens at the harness working directory. Drag files/directories from Finder
or use Upload; drag a row to Finder or use Download in its context menu. Transfers
are streamed, cancellable, sequential, and bound to the original box. Downloads
stage beside the destination and publish without replacing existing paths; a
remote version change discards the staged copy. Symlinks and special files are
refused. Upload replacement checks the observed remote version. Directory uploads
may partially complete and report the first failure; they are not atomic trees.
Hiding the Files pane cancels a transfer started there. Outgoing drags use native
file representations materialized only when the destination asks for them.

## Box management

Actions always target the box named in the confirmation, even if selection changes.
Stop ends running processes; archive also removes the container but retains data.
Restore recreates an archived container and leaves it stopped. Upgrade and repair
replace disposable container state; their dialogs explain what survives. Rename
can start a stopped box because the name is stored inside its workspace. Purge is
offered only for archived boxes and requires typing DELETE. No mutation is retried
automatically. After an ambiguous failure, refresh and inspect the state before retrying.

Repository grouping can be toggled in the sidebar filter menu. Harness and Git
branch details use existing list data, without starting boxes to inspect them.

### Services and Desktop

Open Services on a running box to establish local forwards for its reported ports,
using the same forwarding library and tunnel protocol as the TUI. Desktop is
recognized by its service ID, not a hardcoded port number. Every HTTP/HTTPS port
has its own Open button; other TCP/UDP ports have a copyable local address.
The service process status and the available forwarded ports are shown separately.

Forwards stay alive when the tab is hidden or another box is selected, and
close on disconnect, box stop/removal, explicit rebuild actions, or app exit.
The GUI binds only 127.0.0.1 and checks running state before opening a tunnel.
It never starts a service or a stopped box just to list or open its ports.

### Embedded desktop and text clipboard

Open Desktop in Services opens a separate resizable app window, keeping the
harness visible. The existing viewer, annotations, and sizing logic are preserved.
Copy/Paste buttons and Command-C/V bridge text to and from the Mac clipboard.
Enable **Terminal shortcuts** when focused in a Linux terminal to send Ctrl-Shift-C/V;
leave it off for other apps. Remote text clipboard synchronization is enabled by
default and can be turned off from the window menu. The Mac clipboard is read
only on an explicit paste. Files and images are not part of this text bridge.
The underlying VNC server still determines character-encoding support.

The menu also provides Reconnect, Full Screen, and Open in Browser. Closing the
window ends its viewer connection without stopping the box or Linux desktop.
A client-only loopback proxy appends the clipboard adapter to the existing page's
JavaScript module; no backend files are modified.

Remote access: the backend supports enrolled Iroh identities, but this GUI does
not yet implement Iroh enrollment/transport. Its Unix socket endpoint can instead
be used with an externally managed SSH tunnel to a remote server socket. HTTPS
provides transport encryption; the GUI does not yet provide client authentication.

### Experimental harness quota display

Expand **Harness usage** at the bottom of the box sidebar. While the section is expanded,
its read-only collector checks recorded HTTP audit data once a minute, grouped by
configured harness ID. It searches the latest 200 requests per supported provider
host and reads at most eight matching response bodies per pass. Successful readings
are cached in memory for the connection, with observation and reset times; switching
connections clears them. Multiple boxes on one harness do not add their quotas together.

Initial adapters recognize Codex `wham/usage` rate-limit windows and Claude OAuth
`usage` window payloads, plus five-hour/weekly utilization and reset headers on recorded Claude `/v1/messages` responses. Only quota headers are returned to the UI; message bodies and authentication headers are excluded. These are experimental payload adapters, not a promise that
all harness versions emit or record those requests. Missing, expired, truncated, or
unrecognized recordings cannot provide a current quota. No usage commands are injected
into terminals, no provider refresh is triggered, and provider credentials are not copied.
The offline demo includes an illustrative cached reading. Tests use synthetic payloads;
provider availability still needs validation through normal use on your installation.

The workspace uses a resizable boxes sidebar with explicit window toolbar controls:
sidebar toggle on the left, box actions and inspector on the right. A single
30-point footer holds pending requests and connection status across the
whole window. Normal terminals do not add their own status strip; disconnected
terminals retain a reconnect notice. The compact Usage sidebar section groups available
readings first, collapses harnesses without readings, and shows exact timestamps on
hover. Its disclosure header remembers the expanded/collapsed preference; collapsing
it pauses collection and frees space for boxes. Recording details expand inline.

Use the expand-arrows button in the Agent header to **Maximize agent**. It hides
other workspace panes, the boxes sidebar, and the inspector without closing any
terminals. Press the same button to restore the prior tabs and panel visibility.
The existing remappable leader command (default **Ctrl-A, z**) and Workspace menu
provide the same maximize/restore action. Switching boxes leaves maximized mode.
