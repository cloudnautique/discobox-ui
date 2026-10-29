# Discobox for macOS

> **Preview software:** Development is moving fast, and things will break.
> Expect bugs, rough edges, and breaking changes between builds.

A native Mac app for working with your Discobox coding agents. Keep the agent in
view while you open shells, browse files, review changes, and connect to services.

It connects to an existing Discobox server. Your boxes work in both this app and
the Discobox CLI, and keep running when you close the app.

## What you can do

- Switch between boxes, group them by repository or harness, and filter by tags.
- Work in Ghostty terminals with native keyboard shortcuts and copy/paste.
- Open services and the box’s desktop, transfer files, and browse audit logs.
- Answer approval requests and configure harnesses from macOS Settings.

## Get started

Preview ZIPs are built for Apple Silicon when a `v*` tag is pushed, or when
**Actions → Build preview → Run workflow** is run manually. Download
`Discobox-macos-arm64.zip` from a successful run’s artifacts and move the app to
Applications. These builds are ad-hoc signed and **not notarized**. After the
first blocked launch, use **System Settings → Privacy & Security → Open Anyway**
if you trust the build. See [Apple’s instructions](https://support.apple.com/en-us/102445).

To **build from source**, you’ll need macOS 14 or newer,
Xcode with Swift 6 and the Metal Toolchain, Go 1.27.1 or newer, and Zig 0.14.1.
See the [build guide](docs/DEVELOPMENT.md) for setup details.

From this repository’s directory, get the Discobox source used by the app:

```sh
git clone https://github.com/discobox-ai/discobox.git discobox
git -C discobox checkout d61a7f405389fcc0dda68c5689397aec3a085d9e
```

Then build and launch:

```sh
make ghostty   # First build only
make build
open dist/Discobox.app
```

The app tries your local Discobox server automatically. If it can’t connect, it
shows the connection screen. You can change servers in
**Discobox → Settings → Connections**.

No server handy? Try the demo:

```sh
open dist/Discobox.app --args --demo
```

## Connect to another computer with Iroh

**On the computer running the server:**

Edit its `server.yaml`, preserving any other settings, to enable both listeners:

```yaml
listen:
  - unix://
  - iroh://
```

On macOS, the default file is
`~/Library/Application Support/discobox/server.yaml`. Restart the server with that
config when you can interrupt its current connections:

```sh
discobox --server unix:// admin server shutdown --wait
discobox admin server --config-file "$HOME/Library/Application Support/discobox/server.yaml"
```

The second command runs in the foreground; keep it running or use your service
manager to launch it with the same config. The CLI’s automatic local-server
launcher forces a Unix-only listener, so use the explicit server command for Iroh.
An environment override such as `DISCOBOX_SERVER_LISTEN` takes precedence over YAML.

In another terminal on that computer, check:

```sh
discobox --server unix:// admin server status
```

Look for **this server's own iroh listener**, with an online relay or reachable
direct addresses. Copy the **peer** ID reported **from the server**.

**In the Mac app:**

1. Open **Discobox → Settings → Connections**. Set **This computer’s name** if
   you want a different name from the system default, then choose **Add Connection**.
2. Name the remote computer and enter `discobox://<server-peer-id>` as its address.
3. Expand **Authorize this computer**, choose **Show My Peer ID**, then
   **Copy Enrollment Command**. Run that command on the server computer against
   its local server. For example, replacing the ID and name:

   ```sh
   discobox --server unix:// admin peer add <app-peer-id> --name "Studio Mac"
   ```

4. Back in the app, optionally **Test Connection**, then **Save** and **Connect**.

The app’s peer ID is separate from the CLI’s client ID; enroll the ID shown by
the app. Enrollment grants access to that server’s default user. Connecting a
remote computer keeps your local connection open too.

See the [remote connection guide](docs/REMOTE.md) for troubleshooting, custom
relays, and using several computers together.

## Find your way around

**Left:** your boxes. Use the dropdown to change grouping or filter by tags.
The collapsible usage section shows available harness quota readings; **Details…**
shows when each reading was observed.

**Center:** the agent and your shell/tool tabs. The **+** menu opens shells,
files, audit logs, and other tools. Maximize the agent to give it more room without
changing whether your boxes sidebar is open.

**Right:** Services, Box details, and Tags. Collapse this inspector into a compact
service rail, or hide it entirely using **Settings → Appearance**.

Right-click a box for actions such as start, stop, rename, and archive.
Configure harnesses and manage stored credentials in **Discobox → Settings**.

## Handy shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New box |
| ⌘K | Find and switch boxes |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘[ / ⌘] | Move between panes |
| ⌘⌥I | Show / hide the inspector |
| ⌘H | Workspace help |

Shortcuts are customizable in **Settings → Keybindings**. The default leader is
**Ctrl-A**; press it, then **?** to see leader commands. ⌘H opens help in this app;
Hide Discobox is still available in the app menu.

## Working on the app

```sh
make build    # Rebuild the app
make test     # Run the tests
make ci       # Run all checks and build
make help     # See every target
```

See [Development](docs/DEVELOPMENT.md) for tooling and tests, or
[Architecture](ARCHITECTURE.md) for how the app works.
