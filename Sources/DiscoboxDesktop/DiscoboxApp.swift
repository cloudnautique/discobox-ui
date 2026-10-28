import SwiftUI
import DiscoboxCore

@main
struct DiscoboxApp: App {
    @State private var workspace = Workspace()
    @State private var terminals = TerminalStore()
    @State private var forwards = ServiceForwards()
    @State private var desktops = DesktopWindows()
    @State private var commands = WorkspaceCommands()
    @State private var didAttemptStartup = false

    var body: some Scene {
        Window("Discobox", id: "workspace") {
            WorkspaceView()
                .environment(workspace)
                .environment(terminals)
                .environment(forwards)
                .environment(desktops)
                .environment(commands)
                .tint(DiscoboxAppearance.accent)
                .accentColor(DiscoboxAppearance.accent)
                .onChange(of: workspace.connectionID) { terminals.closeAll(); forwards.closeAll(); desktops.closeAll(); HarnessSetupWindows.shared.closeAll(); commands.resetLayouts() }
                .onChange(of: workspace.pendingBoxActions) {
                    for box in workspace.pendingBoxActions { forwards.close(box: box); desktops.close(box: box) }
                }
                .onChange(of: workspace.sandboxes) {
                    forwards.retainRunningBoxes(workspace.sandboxes)
                    desktops.retainRunningBoxes(workspace.sandboxes)
                }
                .onChange(of: workspace.sandboxID) { commands.restoreAgentLayout(); commands.cancelPrefix(); commands.tab = .terminal }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commands.cancelPrefix() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.disconnect(); CompanionClient.cancelAllRequests(); terminals.closeAll(); forwards.closeAll(); desktops.closeAll(); HarnessSetupWindows.shared.closeAll() }
                .frame(minWidth: 1000, minHeight: 650)
                .task {
                    guard !didAttemptStartup else { return }
                    didAttemptStartup = true
                    // Explicitly set the running app's Dock icon as well as the
                    // bundle icon, which Launch Services may cache across builds.
                    if let url = Bundle.main.url(forResource: "Discobox", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
                        NSApp.applicationIconImage = icon
                    }
                    if ProcessInfo.processInfo.arguments.contains("--desktop-smoke") { await DesktopSmoke.run() }
                    if ProcessInfo.processInfo.arguments.contains("--feature-smoke") { await FeatureSmoke.run() }
                    workspace.streamsLiveTerminals = true
                    commands.install(workspace: workspace)
                    let demoClient = DemoClient()
                    // An explicit demo launch is safe for screenshots and previews.
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--terminal-smoke") || ProcessInfo.processInfo.arguments.contains("--command-smoke") || ProcessInfo.processInfo.arguments.contains("--dialog-smoke") {
                        await workspace.connect(client: demoClient, label: "Demo workspace", demo: true)
                        await workspace.selectBox("demo-ui")
                    } else {
                        await workspace.connect(client: CompanionClient(executable: CompanionLocation.executable, endpoint: "unix://"), label: "unix://")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--terminal-smoke") {
                        await TerminalSmoke.run(workspace: workspace, store: terminals)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--command-smoke") {
                        await CommandSmoke.run(workspace: workspace, commands: commands, terminals: terminals, client: demoClient)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--dialog-smoke") {
                        await DialogSmoke.run(workspace: workspace, commands: commands, terminals: terminals)
                    }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(3)) } catch { break }
                        if workspace.isConnected { await workspace.refresh() }
                    }
                }
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Discobox") { NSApp.hide(nil) }
                Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") { NSApp.unhideAllApplications(nil) }
            }
            CommandGroup(replacing: .help) {
                Button("Workspace Help") { commands.performAppShortcut(.help) }.keyboardShortcut(commands.keyboardShortcut(.help))
            }
            CommandMenu("Workspace") {
                ForEach(AppShortcutAction.allCases.filter { $0 != .help }) { action in
                    Button(action.title) { commands.performAppShortcut(action) }
                        .keyboardShortcut(commands.keyboardShortcut(action))
                        .disabled(!workspace.isConnected)
                }
                Divider()
                ForEach(WorkspaceCommand.allCases) { command in
                    Button(command.title) { commands.perform(command) }
                        .disabled(!workspace.isConnected || (command == .newShell && (workspace.selectedBox?.isRunning != true || workspace.isOpeningShell)))
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Workspace") { Task { await workspace.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!workspace.isConnected)
                Button("Disconnect") { workspace.disconnect() }
                    .disabled(!workspace.isConnected && !workspace.isConnecting)
            }
        }
        Settings {
            TabView {
                AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
                ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
                KeybindingSettings().tabItem { Label("Keybindings", systemImage: "keyboard") }
                HarnessSettings().tabItem { Label("Harnesses", systemImage: "terminal") }
                CredentialSettings().tabItem { Label("Credentials", systemImage: "key") }
            }
            .environment(workspace)
            .environment(commands)
            .tint(DiscoboxAppearance.accent)
            .accentColor(DiscoboxAppearance.accent)
            .frame(width: 640, height: 680)
        }
    }
}

enum CompanionLocation {
    static var executable: URL {
        if let path = ProcessInfo.processInfo.environment["DISCOBOX_DESKTOP_BRIDGE"] {
            return URL(fileURLWithPath: path)
        }
        // build-app.sh places the companion beside the app's executable.
        return Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("discobox-desktop-bridge")
    }
}

private struct SavedConnection: Codable, Identifiable {
    var id: String { endpoint }
    let name: String
    let endpoint: String
    let relayURLs: String
    var directOnly: Bool?
}

struct ConnectionSettings: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("serverEndpoint") private var endpoint = "unix://"
    @AppStorage("savedConnections") private var savedConnections = "[]"
    @State private var name = ""
    @State private var relayURLs = ""
    @State private var directOnly = false
    @State private var peerID = ""
    @State private var error: String?
    @State private var loadingIdentity = false

    private var remote: Bool {
        let scheme = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        return scheme == "discobox" || scheme == "iroh"
    }
    private var profiles: [SavedConnection] {
        (try? JSONDecoder().decode([SavedConnection].self, from: Data(savedConnections.utf8))) ?? []
    }
    var body: some View {
        Form {
            Section("Connection") {
                if !profiles.isEmpty {
                    Menu("Saved connections") {
                        Button("This Mac") { endpoint = "unix://"; name = ""; relayURLs = ""; directOnly = false }
                        ForEach(profiles) { profile in
                            Button(profile.name) { endpoint = profile.endpoint; name = profile.name; relayURLs = profile.relayURLs; directOnly = profile.directOnly ?? false }
                        }
                    }
                }
                TextField("Server endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .help("unix:// for this Mac, or paste the remote server’s discobox://d1-… address.")
                TextField("Connection name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Local socket, existing HTTP/S endpoint, or remote discobox://d1-… peer address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if remote {
                Section("Authorize this Mac") {
                    Text("Enable Iroh on the remote server, then enroll this app’s peer ID there. Enrollment gives this app default-user access to that server.")
                        .font(.caption).foregroundStyle(.secondary)
                    if loadingIdentity { ProgressView("Loading identity…").controlSize(.small) }
                    if !peerID.isEmpty {
                        Text(peerID).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Copy Peer ID") { copy(peerID) }
                            Button("Copy Enrollment Command") { copy("discobox admin peer add \(peerID) --name discobox-desktop") }
                        }
                    } else {
                        Button("Show My Peer ID") { Task { await loadIdentity() } }.disabled(loadingIdentity)
                    }
                    DisclosureGroup("Advanced connection options") {
                        Toggle("Direct connections only", isOn: $directOnly)
                        Text("Direct mode requires an ?addr=IP:port hint and disables relays and discovery.").font(.caption).foregroundStyle(.secondary)
                        TextField("HTTPS relay URLs (comma-separated)", text: $relayURLs).disabled(directOnly)
                        Text("Leave blank for Discobox’s defaults. Custom relays must match the remote server’s configuration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("Launch tries the default local server. Saved connections are opened explicitly. The app never launches or shuts down a server.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = error ?? workspace.connectionError {
                    Text(message).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    if workspace.isConnecting { ProgressView().controlSize(.small) }
                    if profiles.contains(where: { $0.endpoint == endpoint }) {
                        Button("Forget Saved Connection") { save(profiles.filter { $0.endpoint != endpoint }) }
                    }
                    Spacer()
                    Button("Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isConnecting || loadingIdentity)
                }
            }
        }
        .formStyle(.grouped)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func save(_ profiles: [SavedConnection]) {
        if let data = try? JSONEncoder().encode(profiles), let text = String(data: data, encoding: .utf8) { savedConnections = text }
    }
    private func loadIdentity() async {
        loadingIdentity = true; error = nil
        defer { loadingIdentity = false }
        do { peerID = try await IrohConnection.peerID(executable: CompanionLocation.executable, seed: IrohIdentity.seed()) }
        catch { self.error = error.localizedDescription }
    }
    private func connect() {
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let relays = relayURLs
        let isRemote = remote
        let direct = directOnly
        error = nil
        Task {
            do {
                let seed = isRemote ? try IrohIdentity.seed() : nil
                let client = CompanionClient(executable: CompanionLocation.executable, endpoint: address, identitySeed: seed,
                    relayURLs: relays.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, directOnly: direct)
                await workspace.connect(client: client, label: address)
                if workspace.isConnected && workspace.endpointLabel == address {
                    var entries = profiles.filter { $0.endpoint != address }
                    entries.append(SavedConnection(name: displayName.isEmpty ? address : displayName, endpoint: address, relayURLs: relays, directOnly: direct))
                    save(entries)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// A restrained version of the brand purple for native controls and focus.
enum DiscoboxAppearance {
    static let accent = Color(red: 0.73, green: 0.48, blue: 0.86)
}
