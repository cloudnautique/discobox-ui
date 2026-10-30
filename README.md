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
- Use the boxes menu to group and filter the list. **All computers** shows boxes
  from every connected server.
- Open the right-hand inspector for services, box details, and tags.
- Expand **Harness usage** in the sidebar for quota readings and reset times.
- Use **Settings** to choose System, Light, or Dark appearance, customize
  shortcuts, configure harnesses, manage credentials, and enable notifications.

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
