# Discobox for macOS

> **Preview software:** Development is moving fast, and things will break.
> Expect bugs, rough edges, and breaking changes between builds.

A native Mac client for [Discobox](https://github.com/discobox-ai/discobox).
Work with your coding agents, see harness usage, and connect to several Discobox
servers from one app.

## Why use it?

- **A native client experience.** Work in embedded Ghostty terminals with Mac
  keyboard shortcuts and copy/paste. Keep your agent visible alongside shell
  tabs, open services and desktops, browse files and audit logs, and answer
  approval requests through the app or macOS notifications.
- **Harness usage at a glance.** See available Codex and Claude Code subscription
  quota readings, including usage percentages and reset times for supported
  windows such as five hours and weekly. Readings are shown per harness and
  computer, using data already observed by Discobox; they can be delayed or
  unavailable.
- **Multiple servers, one window.** Connect to your local computer and remote
  Discobox servers over Iroh at the same time. View all boxes together or filter
  by computer, then group by repository, harness, state, or tag. Each server
  keeps its own terminals, services, and credentials while you switch.

## 1. Install Discobox first

**You must install and set up Discobox before using this app.** Follow the
[official Discobox installation and getting-started instructions](https://github.com/discobox-ai/discobox#getting-started)
to install the CLI and complete its setup on the computer that will run your boxes.
Make sure you can use Discobox from the terminal before continuing.

This app connects to an existing server. It does not install Discobox or start
its server for you. Your boxes remain available through the Discobox CLI and
keep running when you quit the Mac app.

## 2. Download the Mac app

Preview builds require **Apple Silicon (M1 or newer)** and **macOS 14 or newer**.

1. Open [Releases](https://github.com/cloudnautique/discobox-ui/releases).
2. Under a release’s **Assets**, download **`Discobox-macos-arm64.zip`**.
   The **Source code** archives are not the app.
3. Unzip the download and drag **Discobox.app** into **Applications**.

If a release has no app ZIP attached yet, open
[Actions → Build preview](https://github.com/cloudnautique/discobox-ui/actions/workflows/build.yml),
choose a successful run, and download its app ZIP from **Artifacts**. GitHub may
require you to sign in to download an Actions artifact.

## 3. Open the unsigned preview

Preview builds are **not signed with an Apple Developer ID and are not notarized**.
macOS may block the first launch. If you trust the downloaded build:

1. Open **Discobox** from Applications once. If macOS blocks it, dismiss the alert.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Find the message about Discobox and click **Open Anyway**.
4. Confirm **Open** in the next prompt. Authenticate if macOS asks.

After that, open Discobox normally from Applications. See
[Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445)
for more detail.

## 4. Connect and start working

On launch, the app tries the default local Discobox server. If the server is
running, your boxes appear automatically. Otherwise, the app shows a connection
screen; check that you have completed Discobox’s setup and started its server.
Manage saved computers in **Discobox → Settings → Connections**.
Computers you connect to retry automatically after network interruptions, including
when the first attempt cannot reach the host. The app keeps your last-known boxes
and selection visible, backs off between retries, and checks again after wake or
network restoration. Use **Retry now** to check immediately; **Disconnect** stops
retries. Authorization or certificate errors need your attention before retrying.

- Press **⌘N** to create a box or **⌘K** to find and switch boxes.
- Use the **+** beside a repository to create a box with that repository filled
  in, or choose a recent repository from the dropdown in **New box**.
- Keep the agent beside your shell tabs. **Split** shows two shells together;
  **Merge** returns them to tabs. **⌘J** hides or restores the shell area without
  stopping its sessions. Right-click a shell tab to rename it.
- In **New box → Box secrets**, add a secret value, its environment
  variable (for example `OBOT_MCP_TOKEN`), and its allowed host (for example
  `demo.on-obot.ai`). Reference `${OBOT_MCP_TOKEN}` in your repository’s MCP
  headers. The selected server stores the token and assigns it during creation;
  the shared harness stays unchanged. Discobox 0.18 may ask for approval on first
  use. Closing the window or changing computers clears unsaved token drafts.
- Opening a stopped box offers **Start & Open** or **View Saved**. Saved terminal
  output also has a **Start Box** button, even when your sidebar filters hide it.
- Creating a box keeps your filters. A temporary **New boxes** row shows startup
  progress or errors; **Reveal** shows a running box hidden by your filters.
- Use the boxes menu to group and filter the list. **All computers** shows boxes
  from every connected server.
- Select boxes with **⌘-click** or **⇧-click**, then use **Actions…** or the
  selection’s context menu to start, stop, archive, restore, upgrade, or repair
  them. Bulk actions apply to one computer at a time and show a confirmation
  listing the boxes and pools. Only actions available for every selected box
  are offered. Archived boxes also support **Purge Selected…**.
- **Resources → Stop Selected…** asks for confirmation. Cache cleanup can keep
  running after you close its dialog; reopen Resources for its status and result.
- Choose **Editor** in the title bar to open the selected box’s workspace in
  VS Code or Zed on this Mac. After a successful launch, click the app icon to
  open another box in the same editor, or use the arrow to switch. You can
  also right-click a box and choose **Open in Editor**. This uses the installed
  Discobox CLI and its SSH aliases. Remote computers must admit the CLI’s peer.
- Use **Desktop** in the title bar to open the box’s desktop, or **Services**
  for its ports. The inspector also holds box details and tags.
- Expand **Harness usage** in the sidebar for quota readings and reset times.
- Choose **Settings → Harnesses → Make Default** to select the harness preselected
  in New box. This is saved on the selected server/project and shared with other
  Discobox clients. You can choose a different harness for each box.
- To save a harness login or settings, sign in or make changes **inside a box**.
  Choose **Login/settings changed → Review…** in that box, review the account,
  files and replacement behavior, then **Save changes**. The save applies to that
  harness on that server; other computers and account variants stay separate.
  **Settings → Harnesses → Login & Settings…** shows saved state and recovery
  options. Refreshable OAuth logins renew on the server; a copied access token
  does not include refresh credentials. Older servers and unsupported harnesses
  show a matching-CLI or capability explanation.
- For a manager box, choose **New box → Discobox API access → Enable for this
  box**. This explicitly enables API access during creation, within Discobox’s
  permissions; it grants no credential access. Set a default under that
  harness’s **Login & Settings → New box defaults**. Defaults belong to this app,
  computer, project and exact harness, and can be overridden for each launch.
- Credential notifications offer **Review…**, **Deny**, or **Later**. Review shows
  the computer, box, access and lifetime before approval. Shared credential limits
  can be reviewed separately in **Settings → Credentials → Details…**. Choose an existing
  credential or **+ New credential…** to save a token inline, then use **Approve**
  or **Deny** at the bottom. Saving a credential does not approve the request.
- Use **Settings** to choose System, Light, or Dark appearance, customize
  shortcuts, configure harnesses, manage credentials, and enable notifications.

### Open a box link

Command-click a `discobox:///sbx_…` link in the agent or a shell to open that box
on the same computer as the terminal. A link such as
`discobox://<server-peer-id>/sbx_…` can open a box on another connected computer.
You can also open these links from other apps; a link without a server uses
the currently selected computer. On launch, it uses this computer.

Links select the box without starting it or changing your list filters.
Choose **Desktop** to open its desktop. Stopped boxes keep their **Start Box**
action. If the computer is not connected, connect in **Settings → Connections**
first; clicking a link never registers a new computer automatically.

During an interruption, the terminal shows **Reconnecting** while it retries the
existing session. **Copy Text** works from the locally retained output even when
the computer is unavailable. **Previous Output…** keeps text from before a
reattachment available to select and copy. Reconnecting does not start stopped
boxes or create replacement agent sessions.

### Move files in and out

Open a running box’s **Files** tab. It starts in the agent’s working directory;
**Source** takes you back there. Drag files or folders from Finder into the list
to upload, or drop onto a folder to copy into it. Select several items with
Command or Shift, then drag them to Finder to download. Transfers also work
with remote boxes over the existing connection.

Existing remote names prompt before replacement. Downloads never replace an
existing local file. **Upload…** and the download button offer the same transfers
without dragging. The box, pool, and server must support Discobox’s Files API.
Discobox v0.18.0/v0.18.1 do not include it; updating only this Mac app is not enough.

## Connect to another computer with Iroh

Install and set up Discobox on the remote computer, then enable its Iroh listener.
In the Mac app, choose **Settings → Connections → Add Connection**, name the
computer, and enter its `discobox://<server-peer-id>` address. Use **Authorize
this computer** to copy an enrollment command and run it on the server computer.
Then save the connection and click **Connect**.

The [remote connection guide](docs/REMOTE.md) walks through the server config,
starting its listener, finding the correct peer ID, and enrolling the Mac app.
Adding a remote server keeps your local connection open.

### Terminal connection diagnostics

The app records transport metadata in
`~/Library/Logs/Discobox/diagnostics/transport.jsonl`, with three rotated files and an
8 MiB total log limit. Logs include attachment/box/terminal identifiers,
connection attempts, ping results, byte counts, delivery progress, and proxy
shutdown events. They exclude terminal contents, keystrokes, credentials, and
raw transport error text. Logging is bounded and can drop records under load;
subsequent records report the dropped count.

For a freeze report, include these logs and the incident time. The
`proxy_ready` event links a remote host's endpoint hash to its private socket;
`proxy_upgrade_started` links it to the terminal helper's session. Packaged
builds record both UI and upstream source revisions. A direct-path discovery
is recorded separately from path selection: the current upstream API does not
expose continuous direct/relay selection, so selection is reported as unknown.

If local terminal delivery stops progressing for five seconds, or its bounded
queue fills, the app closes that attachment and keeps the displayed output
read-only with **Copy Text** and **Reconnect** available. It waits up to 30
seconds for local delivery, then attempts screen replay with bounded retries.
Three repeated stalls require an explicit reconnect. Verify the last command
before re-entering it: input queued during the stall is not sent on recovery.
Replay restores screen state, not a complete history of output while detached.
This does not stop or restart the box.

## Building from source

You do not need Xcode or the app’s source code to use a downloaded preview.
To build or contribute, follow the [development guide](docs/DEVELOPMENT.md).
See [Architecture](ARCHITECTURE.md) for implementation details.
