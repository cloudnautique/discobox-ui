#if DEBUG
@testable import DiscoboxUI
import SwiftUI
import DiscoboxCore

/// Offline fixtures use the production composition, including for a single host.
@MainActor struct WorkspaceFixture {
    let connections: Connections
    let runtimes = ConnectionRuntimes()
    let commands: WorkspaceCommands
    private let defaults: UserDefaults
    private let suite: String
    private init(connections: Connections) {
        self.connections = connections
        suite = "ai.discobox.smoke.workspace." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        commands = WorkspaceCommands(defaults: defaults)
    }
    static func make(client: any DiscoboxClient = DemoClient()) async throws -> Self {
        let connections = Connections(polling: false)
        _ = try await connections.connect(.thisComputer, demo: true) { client }
        return Self(connections: connections)
    }
    func close() {
        connections.disconnectAll(); runtimes.closeAll()
        defaults.removePersistentDomain(forName: suite)
    }
    var view: some View {
        ConnectedWorkspace(connections: connections, runtimes: runtimes, commands: commands).defaultAppStorage(defaults)
    }
}
#endif
