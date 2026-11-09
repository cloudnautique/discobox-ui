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
- Use **Desktop** in the title bar to open the box’s desktop, or **Services**
  for its ports. The inspector also holds box details and tags.
- Expand **Harness usage** in the sidebar for quota readings and reset times.
- Use **Settings** to choose System, Light, or Dark appearance, customize
  shortcuts, configure harnesses, manage credentials, and enable notifications.

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

## Building from source

You do not need Xcode or the app’s source code to use a downloaded preview.
To build or contribute, follow the [development guide](docs/DEVELOPMENT.md).
See [Architecture](ARCHITECTURE.md) for implementation details.
