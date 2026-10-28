# Connect to a remote Discobox server

Use Iroh to connect the Mac app to Discobox on another machine. The remote server
must already have Iroh enabled, and you’ll need someone with access to that host
to enroll this app.

## Connect

1. Open **Discobox → Settings → Connection**.
2. Enter the server’s `discobox://d1-…` address. `iroh://d1-…` also works.
3. Click **Show My Peer ID**, then **Copy Enrollment Command**.
4. On the remote host, run that command against the intended Discobox server:

   ```sh
   discobox admin peer add <app-peer-id> --name discobox-desktop
   ```

5. Back in the app, click **Connect**.

Successful connections appear in **Saved connections**. The app currently uses
one server at a time; connecting to another replaces the current connection.
On launch, it still tries the default local server first.

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
