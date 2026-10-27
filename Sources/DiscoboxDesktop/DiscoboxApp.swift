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
                .onChange(of: workspace.connectionID) { terminals.closeAll(); forwards.closeAll(); desktops.closeAll(); commands.resetLayouts() }
                .onChange(of: workspace.pendingBoxActions) {
                    for box in workspace.pendingBoxActions { forwards.close(box: box); desktops.close(box: box) }
                }
                .onChange(of: workspace.sandboxes) {
                    forwards.retainRunningBoxes(workspace.sandboxes)
                    desktops.retainRunningBoxes(workspace.sandboxes)
                }
                .onChange(of: workspace.sandboxID) { commands.restoreAgentLayout(); commands.cancelPrefix(); commands.tab = .terminal }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commands.cancelPrefix() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in CompanionClient.cancelAllRequests(); terminals.closeAll(); forwards.closeAll(); desktops.closeAll() }
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
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--terminal-smoke") || ProcessInfo.processInfo.arguments.contains("--command-smoke") {
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
                ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
                KeybindingSettings().tabItem { Label("Keybindings", systemImage: "keyboard") }
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

struct ConnectionSettings: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("serverEndpoint") private var endpoint = "unix://"

    var body: some View {
        Form {
            Section {
                TextField("Server endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .help("unix:// selects the existing local socket. You can also enter unix:///path/to/server.sock or an existing HTTP/S endpoint.")
                Text("Use unix:// for the existing local server, or enter a Unix socket path as a URL or an HTTP/S endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Connection") }
            Section {
                Text("On launch, the app tries the default local server. You can connect to another endpoint here. It never launches or shuts down your server.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Iroh and Discobot authentication are not available in this build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if workspace.isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isConnecting)
            }
        }
        .formStyle(.grouped)
    }

    private func connect() {
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await workspace.connect(client: CompanionClient(executable: CompanionLocation.executable, endpoint: address), label: address) }
    }
}

/// A restrained version of the brand purple for native controls and focus.
enum DiscoboxAppearance {
    static let accent = Color(red: 0.73, green: 0.48, blue: 0.86)
}
