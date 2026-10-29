# Connect to a remote Discobox server

Use Iroh to connect the Mac app to Discobox on another machine. The remote server
must already have Iroh enabled, and you’ll need someone with access to that host
to enroll this app.

For host configuration, starting the server with its Iroh listener, and finding
the server’s peer ID, see [Iroh setup in the README](../README.md#connect-to-another-computer-with-iroh).

## Connect

1. Open **Discobox → Settings → Connections**. **This computer’s name** defaults
   to the system computer name; enter a different name if you prefer. Then choose
   **Add Connection**.
2. Give the computer a name and paste its `discobox://d1-…` address.
   `iroh://d1-…` also works.
3. Expand **Authorize this computer**, click **Show My Peer ID**, then
   **Copy Enrollment Command**.
4. On the remote host, run that command against the intended Discobox server:

   ```sh
   discobox --server unix:// admin peer add <app-peer-id> --name "Studio Mac"
   ```

   The copied command uses **this computer’s** name, identifying the client to
   the remote server. The connection's **Name** field names the remote computer
   in your sidebar. Renaming this computer changes future copied commands; it
   does not rename a peer already registered on another server.

5. Back in the app, optionally click **Test Connection**. If access is refused,
   the editor keeps your details and shows enrollment instructions.
6. Click **Save**, select the connection in the list, and click **Connect**.

You can save the name, address, and options before completing enrollment or when
the server is offline. Testing is optional, and it never saves or closes the editor.

Testing uses a separate client and leaves your current workspaces connected.
Saved computers appear by name in the Connections list. Click **Connect** to keep
another computer connected alongside **Name (This computer)**. **Show Boxes** selects an already
connected computer; **Disconnect** closes only that computer’s GUI connection.
On launch, it still tries the default local server on **This computer** first.
**Edit…** lets you rename or reconfigure a saved connection; **Remove…** removes
its saved address without revoking access or disconnecting an active workspace.

## Identity and access

The app has its own identity stored in macOS Keychain, separate from the CLI.
Enroll each Mac separately. Enrollment grants default-user access on that server,
not access to just one box.

Forgetting a saved connection does not revoke access. To remove access, revoke
the app’s peer on the server. Reinstalling the app on the same Mac can reuse its
Keychain identity.

Services and Desktop use local port forwards through the connection. Disconnecting
closes the app’s connection and forwards; the remote boxes keep running.

## If it doesn’t connect

- **Access refused:** check that the app’s peer ID is enrolled on the intended
  server and has not been revoked.
- **Connection failure:** check the address, network, and server’s Iroh listener.
- **Custom relays:** the advanced HTTPS relay settings must match the server.
- **Direct-only mode:** requires a reachable `?addr=IP:port` in the server address;
  it disables discovery and relays.

For a local server, use `unix://` or a specific
`unix:///absolute/path/server.sock` address. HTTP/S endpoints are also supported,
but do not add client authentication. Discobot authentication is not supported.

## Use several computers together

The sidebar groups boxes by computer, with separate connection and approval
indicators. Click any box to open it. Terminals, tabs, port forwards, and desktop
windows remain attached to their own computer while you switch.

- **⌘K** searches boxes across connected computers, including computer names,
  harnesses, and repositories. Return opens the selected result.
- **⌘N** defaults to the selected computer and offers a Computer picker.
- Harnesses and Credentials settings have a Computer picker. Usage readings
  belong to each computer and harness; accounts are not merged across hosts.
- Archived multi-selection and purge remain scoped to the selected computer.
- A failed or disconnected computer leaves other connections running.

Connected computers are retained for this app session. On launch the app still
tries This computer first; reconnect saved remote computers explicitly.
