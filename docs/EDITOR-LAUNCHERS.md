# Open a box in VS Code or Zed

**Discobox Desktop editor launcher design.** A user inspecting an agent should be able to open that box’s working directory in an editor on their Mac and return to the same agent terminal afterwards.

## What the user sees

Give the editor launcher its own toolbar item between **New shell** and **Desktop**. Use the installed application’s icon and name when there is a preferred editor. Clicking the name opens the selected box in that editor. The chevron opens a native menu for choosing another editor. Keep **Open in Editor** in the single-box sidebar context menu as a shortcut.

```text
work-laptop › API cleanup       New shell   [ VS Code | ▾ ]   Desktop   Services   …
                                            ┌───────────────┐
                                            │ ✓ VS Code     │
                                            │   Zed         │
                                            └───────────────┘
```

Choosing an editor opens a window on this Mac at the box’s primary source directory. A box without a source opens at its working root. The sidebar context menu targets the clicked row, even when the terminal is showing a different box or computer. Opening the editor leaves the sidebar selection and terminal session in place.

Discover installed editors locally via Launch Services at app startup. Check again when the menu opens and validate the executable before launch. This requires no calls to a box. Share the last successfully launched editor across computers on this Mac.

| Detected on this Mac | Toolbar on first use |
| --- | --- |
| Both editors | Show **Editor ▾** with a neutral code icon. The first click opens the menu with both app icons. Choosing **Zed** launches it and changes the button to **Zed ▾** for next time. |
| One editor | Show that editor’s icon and name immediately. Its primary action launches in one click. |
| Neither | Keep **Editor ▾** visible. The menu shows **No supported editor found** and **Locate Editor…** for an existing installation. |

If the remembered editor disappears, use the same detection rules. At narrow widths keep the icon and chevron visible and drop the text label first. Give the item its own native toolbar space outside the current fixed-width action group. Provide a tooltip and VoiceOver label such as “Open API cleanup in Zed,” with “Choose editor” for the menu.

| Situation | Interaction |
| --- | --- |
| One connected, running box | One click on the editor name launches it. Coalesce repeated clicks while the handoff is in progress. |
| Stopped box | Offer **Start & Open in VS Code…** or **Start & Open in Zed…** through the existing start confirmation. Recheck the original connection and box after start. |
| Archived box, disconnected computer, demo, or multiple selection | Disable the action. An editor action has one live destination. |
| Editor or CLI missing | Keep the chosen editor identifiable. Show which component is missing and offer **Locate…** for an existing install. For an older CLI, explain which command it needs. |
| First-time SSH setup | Explain that Discobox uses managed SSH aliases on this Mac. Offer **Copy Setup Command** for `discobox admin ssh-config enable` and **Already Configured** for an existing setup. The enable command opts into Include lines in the user’s SSH config and refreshes configured servers. |
| Remote computer rejects the CLI | Name the computer and offer **Copy CLI Enrollment Command** using the CLI’s own peer ID. The desktop app and installed CLI have separate Iroh identities. |

Show launch errors against the initiating box. Report a successful handoff as “Opened VS Code” or “Opened Zed” only to the extent the launcher confirms it. The editor handles its SSH connection and first-run prompts. VS Code requires Remote - SSH. Zed may need its **upload_binary_over_ssh** setting when the box cannot download the editor server.

## How the handoff works

1. Capture the connection generation, durable server endpoint, resolved project ID, and full box ID at click time. A selection change must never redirect an action to another box. Invalidate an outstanding start or setup continuation if the connection is replaced.
2. Find the installed Discobox CLI and the requested editor’s launcher. Finder-launched apps may have a different PATH from an interactive shell. Resolve the application with Launch Services and use its shipped launcher when available. Pass the resolved launcher with `--program` so **VS Code** opens the selected application even on a Mac with several compatible editors installed.
3. Start the CLI asynchronously with a fixed argument vector and closed stdin. The following illustrates the arguments for VS Code. Zed substitutes `zed` and its launcher path. Using the box address relative to the explicitly selected server scopes lookup to that server. A bare ID can cause the CLI to search its registry.

   ```sh
   discobox --auto-start-server=false --server "$server" --project "$project_id" \
     tools vscode --program "$editor_launcher" "discobox:///$box_id"
   ```

4. Use the profile’s durable address, such as its local Unix socket or its Iroh peer address. The editor’s SSH config persists and can be used after Discobox Desktop quits. The private socket owned by the desktop Iroh proxy expires on disconnect. Let the installed CLI use its own identity and keep app credentials, inherited endpoint overrides, and bearer tokens out of the child environment.
5. Let upstream resolve the working directory, refresh the server/project-specific SSH config and known hosts, and invoke the editor. The CLI owns the SSH proxy used by later editor connections. Swift owns the menu, target capture, subprocess lifetime through handoff, and actionable errors. The existing Go companion continues to handle in-box tools and terminal sessions. Only locally defined editor actions select a host launcher.

Upstream’s noninteractive command can emit an SSH Include setup hint and still start the editor. A zero exit status alone cannot verify SSH readiness. Respect existing manually configured aliases and keep setup and retry available. Resolve the editor at launch time and avoid background capability polling. [Upstream host tools design](https://github.com/discobox-ai/discobox/blob/97b22818452f39b5e8e05ea83f27d2d4c0a6b332/cli/DESIGN.md) · [SSH transport](https://github.com/discobox-ai/discobox/blob/97b22818452f39b5e8e05ea83f27d2d4c0a6b332/docs/adr/0057-ssh-reaches-the-server-only-through-the-cli-transport.md)

## Delivery and verification

The offline `--editor-launcher-smoke` fixture drives the native toolbar buttons and dropdown with disposable editor bundles, a recording CLI, and an in-memory computer. It checks initial discovery, installation while the picker is open in the app, removal, preference persistence, duplicate clicks, the handoff argument vector including spaces, and disconnect during start confirmation.

Live acceptance covers opening and saving a file with each editor on a local box and over Iroh, and reconnecting after Discobox Desktop quits. The installed CLI must be enrolled for remote access. Direct-only profiles show an explanation because the CLI’s generated SSH proxy cannot enforce that transport setting.

**Feasibility check.** The local upstream checkout matched fetched main at `97b228184`. On macOS, upstream’s fake-editor tests exercised both default launches, worktree fallback and missing-editor handling. One unmodified VS Code override test failed because it wrote its declaration under `~/.config` while the loader uses macOS’s application-support directory. With the fixture path corrected in a temporary Go test overlay, that case passed. The overlay also verified the addressed command above for both editors. A live editor-to-box connection remains an implementation acceptance check.
