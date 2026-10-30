import SwiftUI
import DiscoboxCore

@main
struct DiscoboxApp: App {
    @NSApplicationDelegateAdaptor(DiscoboxApplicationDelegate.self) private var applicationDelegate
    @State private var connections = Connections()
    @State private var runtimes = ConnectionRuntimes()
    @AppStorage("savedConnections") private var savedConnections = "[]"
    @AppStorage("computerName") private var computerName = ""
    @AppStorage(DiscoboxAppearance.preferenceKey) private var appearance = DiscoboxAppearance.Mode.system
    private var localProfile: ConnectionProfile { .localComputer(name: computerName) }
    private var workspace: Workspace { connections.active.workspace }
    private var terminals: TerminalStore { runtimes.runtime(connections.activeID).terminals }
    private var forwards: ServiceForwards { runtimes.runtime(connections.activeID).forwards }
    private var desktops: DesktopWindows { runtimes.runtime(connections.activeID).desktops }
    @State private var commands = WorkspaceCommands()
    @State private var didAttemptStartup = false

    var body: some Scene {
        Window("Discobox", id: "workspace") {
            ConnectedWorkspace(connections: connections, runtimes: runtimes, commands: commands)
                .onChange(of: appearance, initial: true) { DiscoboxAppearance.apply(appearance) }
                .onChange(of: savedConnections) { connections.syncProfiles(ConnectionProfiles.decode(savedConnections) ?? []) }
                .onChange(of: computerName, initial: true) { connections.syncProfiles([localProfile]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await ApprovalNotifications.shared.refreshAuthorization() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in connections.disconnectAll(); CompanionClient.cancelAllRequests(); runtimes.closeAll(); HarnessSetupWindows.shared.closeAll() }
                .frame(minWidth: 1000, minHeight: 650)
                .task {
                    guard !didAttemptStartup else { return }
                    didAttemptStartup = true
                    // Explicitly set the running app's Dock icon as well as the
                    // bundle icon, which Launch Services may cache across builds.
                    if let url = Bundle.main.url(forResource: "Discobox", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
                        NSApp.applicationIconImage = icon
                    }
                    if ProcessInfo.processInfo.arguments.contains("--multihost-smoke") { await MultiHostSmoke.run() }
                    if ProcessInfo.processInfo.arguments.contains("--desktop-smoke") { await DesktopSmoke.run() }
                    if ProcessInfo.processInfo.arguments.contains("--feature-smoke") { await FeatureSmoke.run() }
                    workspace.streamsLiveTerminals = true
                    commands.install(workspace: workspace, connections: connections)
                    connections.syncProfiles(ConnectionProfiles.decode(savedConnections) ?? [])
                    let demoClient = DemoClient()
                    // An explicit demo launch is safe for screenshots and previews.
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--terminal-smoke") || ProcessInfo.processInfo.arguments.contains("--command-smoke") || ProcessInfo.processInfo.arguments.contains("--dialog-smoke") {
                        _ = try? await connections.connect(localProfile, demo: true) { demoClient }
                        await workspace.selectBox("demo-ui")
                    } else {
                        _ = try? await connections.connect(localProfile) { CompanionClient(executable: CompanionLocation.executable, endpoint: "unix://") }
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
                    ApprovalNotifications.shared.configure(connections)
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
                        .disabled(!workspace.isConnected && !(action == .switchBox && connections.sessions.contains(where: { $0.workspace.isConnected })))
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
                Button("Disconnect Selected Computer") { connections.disconnect(connections.activeID) }
                    .disabled(!workspace.isConnected && !workspace.isConnecting)
            }
        }
        Settings {
            TabView {
                AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
                ApprovalNotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
                ConnectionSettings().tabItem { Label("Connections", systemImage: "network") }
                KeybindingSettings().tabItem { Label("Keybindings", systemImage: "keyboard") }
                VStack { ComputerPicker().padding([.horizontal, .top]); HarnessSettings().id(connections.activeID) }.tabItem { Label("Harnesses", systemImage: "terminal") }
                VStack { ComputerPicker().padding([.horizontal, .top]); CredentialSettings().id(connections.activeID) }.tabItem { Label("Credentials", systemImage: "key") }
            }
            .environment(workspace)
            .environment(connections)
            .environment(commands)
            .tint(DiscoboxAppearance.accent)
            .accentColor(DiscoboxAppearance.accent)
            .frame(width: 640, height: 680)
            .onChange(of: appearance, initial: true) { DiscoboxAppearance.apply(appearance) }
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

/// A restrained version of the brand purple for native controls and focus.
enum DiscoboxAppearance {
    static let preferenceKey = "appAppearance"
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
        }
    }
    /// AppKit owns the override so existing SwiftUI sheets, native alerts,
    /// and separately-created desktop/setup windows all inherit it. Nil lets
    /// macOS propagate automatic appearance changes without another observer.
    @MainActor static func apply(_ mode: Mode) {
        let name: NSAppearance.Name?
        switch mode { case .system: name = nil; case .light: name = .aqua; case .dark: name = .darkAqua }
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
    }
    static let accent = adaptive(light: NSColor(red: 0.50, green: 0.37, blue: 0.72, alpha: 1), dark: NSColor(red: 0.74, green: 0.64, blue: 0.90, alpha: 1))
    static let canvas = adaptive(light: NSColor(red: 0.985, green: 0.985, blue: 0.993, alpha: 1), dark: NSColor(red: 0.125, green: 0.125, blue: 0.14, alpha: 1))
    static let chrome = adaptive(light: NSColor(red: 0.972, green: 0.972, blue: 0.98, alpha: 1), dark: NSColor(red: 0.162, green: 0.16, blue: 0.18, alpha: 1))
    static let sidebar = adaptive(light: NSColor(red: 0.943, green: 0.939, blue: 0.96, alpha: 1), dark: NSColor(red: 0.147, green: 0.145, blue: 0.164, alpha: 1))
    static let surface = adaptive(light: NSColor(red: 0.958, green: 0.954, blue: 0.973, alpha: 1), dark: NSColor(red: 0.18, green: 0.175, blue: 0.20, alpha: 1))
    static let border = adaptive(light: NSColor(red: 0.86, green: 0.85, blue: 0.89, alpha: 1), dark: NSColor(red: 0.225, green: 0.22, blue: 0.25, alpha: 1))
    static let selection = accent.opacity(0.14)
    static let terminalInset: CGFloat = 8
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
