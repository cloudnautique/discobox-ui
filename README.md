# Discobox for macOS

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

This is currently a **build-from-source app**. You’ll need macOS 14 or newer,
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
**Discobox → Settings → Connection**.

No server handy? Try the demo:

```sh
open dist/Discobox.app --args --demo
```

To use a server on another machine, follow the
[remote connection guide](docs/REMOTE.md).

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
