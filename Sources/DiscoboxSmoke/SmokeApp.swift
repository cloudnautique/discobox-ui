#if DEBUG
import AppKit
import SwiftUI
import DiscoboxCore
@testable import DiscoboxUI

/// Offline launcher. It has no production startup, saved hosts, notification
/// registration, or implicit local-server connection.
@main struct DiscoboxSmokeApp: App {
    @State private var connections = Connections(polling: false)
    @State private var runtimes = ConnectionRuntimes()
    @State private var started = false
    private let defaults: UserDefaults
    private let suite: String
    @State private var commands: WorkspaceCommands

    init() {
        let suite = "ai.discobox.smoke.launcher." + UUID().uuidString
        self.suite = suite
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        _commands = State(initialValue: WorkspaceCommands(defaults: defaults))
        BrandTypography.register()
    }
    var body: some Scene {
        Window("Discobox · Smoke fixtures", id: "smoke") {
            ConnectedWorkspace(connections: connections, runtimes: runtimes, commands: commands)
                .modifier(AuxiliaryWindowActions())
                .defaultAppStorage(defaults)
                .frame(minWidth: 1000, minHeight: 650)
                .task {
                    guard !started else { return }
                    started = true
                    await run()
                }
        }.defaultSize(width: 1320, height: 850)
        AuxiliaryWindowScenes()
    }
    @MainActor private func run() async {
        defer { connections.disconnectAll(); runtimes.closeAll(); defaults.removePersistentDomain(forName: suite) }
        let arguments = Set(ProcessInfo.processInfo.arguments.dropFirst())
        let standalone: [(String, @MainActor () async -> Void)] = [
            ("--native-window-smoke", { await NativeWindowSmoke.run() }),
            ("--sidebar-swipe-smoke", { await SidebarSwipeSmoke.run() }),
            ("--sidebar-manual-swipe-smoke", { await SidebarSwipeSmoke.run() }),
            ("--terminal-recovery-smoke", { await TerminalRecoverySmoke.run() }),
            ("--terminal-input-smoke", { await TerminalInputSmoke.run() }),
            ("--box-link-smoke", { await BoxLinkSmoke.run() }),
            ("--approval-workflow-smoke", { await ApprovalWorkflowSmoke.run(connections: connections, commands: commands) }),
            ("--binding-conflict-smoke", { await BindingConflictSmoke.run() }),
            ("--agent-activity-smoke", { await AgentActivitySmoke.run() }),
            ("--approval-queue-smoke", { await ApprovalQueueSmoke.run() }),
            ("--harness-smoke", { await HarnessManagementSmoke.run() }),
            ("--recovery-smoke", { await ConnectionRecoverySmoke.run() }),
            ("--recovery-terminal-smoke", { await ConnectionRecoverySmoke.run(includeTerminal: true) }),
            ("--multihost-smoke", { await MultiHostSmoke.run() }),
            ("--desktop-smoke", { await DesktopSmoke.run() }),
            ("--feature-smoke", { await FeatureSmoke.run() }),
            ("--files-smoke", { await FilesSmoke.run() })
        ]
        let embedded = ["--terminal-smoke", "--command-smoke", "--dialog-smoke", "--sidebar-layout-smoke"]
        let selected = arguments.intersection(Set(standalone.map(\.0) + embedded))
        guard selected.count == 1, let flag = selected.first else {
            print("Choose one smoke check:\n" + (standalone.map(\.0) + embedded).joined(separator: "\n"))
            fflush(stdout); exit(arguments.contains("--help") ? 0 : 2)
        }
        if let check = standalone.first(where: { $0.0 == flag }) { await check.1(); return }
        let client = DemoClient()
        do {
            let session = try await connections.connect(.thisComputer, demo: true) { client }
            await session.selection.selectBox("demo-ui")
            let terminals = runtimes.runtime(session.id).terminals
            switch flag {
            case "--sidebar-layout-smoke":
                connections.syncProfiles([.init(name: "Laptop", endpoint: "https://laptop.invalid"),
                                          .init(name: "Desktop", endpoint: "https://desktop.invalid")])
                defaults.set(320.0, forKey: "harnessUsageShelfHeight")
                try await SidebarLayoutSmoke.run(session: session, store: terminals, commands: commands)
            case "--terminal-smoke": await TerminalSmoke.run(workspace: session, store: terminals)
            case "--command-smoke": await CommandSmoke.run(workspace: session, connections: connections, commands: commands, terminals: terminals, client: client)
            case "--dialog-smoke": await DialogSmoke.run(workspace: session, commands: commands, terminals: terminals)
            default: break
            }
        } catch { print("SMOKE_STARTUP_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
}
#else
import Foundation
@main struct SmokeRequiresDebug {
    static func main() {
        print("Build the fixture runner with: swift build --product DiscoboxSmoke --configuration debug")
        exit(2)
    }
}
#endif
