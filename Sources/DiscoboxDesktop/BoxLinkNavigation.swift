import AppKit
import SwiftUI
import DiscoboxCore

/// One navigation owner for terminal links and URLs delivered by macOS.
/// Keep the source selection until lookup finishes; a late result never
/// pulls someone back after they have moved to a different box.
@MainActor @Observable final class BoxLinkNavigation {
    var error: String?
    private var ready = false
    private var pending: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func receive(_ raw: String, connections: Connections, commands: WorkspaceCommands) {
        guard ready else { pending = raw; return }
        open(raw, reader: connections.active, connections: connections, commands: commands)
    }

    func finishStartup(connections: Connections, commands: WorkspaceCommands) {
        ready = true
        if let pending {
            self.pending = nil
            receive(pending, connections: connections, commands: commands)
        }
    }

    func open(_ raw: String, reader: ConnectionSession, connections: Connections, commands: WorkspaceCommands) {
        task?.cancel()
        error = nil
        guard BoxLinks.claims(raw), let host = connections.sessions.first(where: { $0 === reader }) else {
            error = "This is not a supported Discobox box link."
            return
        }
        let active = connections.activeID, sourceBox = reader.selection.sandboxID, generation = reader.connectionState.connectionID
        task = Task {
            do {
                let target = try await connections.resolveBoxLink(raw, readerID: host.id, generation: generation)
                try Task.checkCancellation()
                guard connections.activeID == active, reader.selection.sandboxID == sourceBox else { return }
                commands.restoreAgentLayout()
                try await connections.openBoxLink(target)
                NSApp.activate(ignoringOtherApps: true)
                commands.window?.makeKeyAndOrderFront(nil)
            } catch is CancellationError {
                // A newer click, navigation or reconnect supersedes this one.
            } catch {
                guard !Task.isCancelled, connections.activeID == active,
                      reader.connectionState.connectionID == generation, reader.selection.sandboxID == sourceBox else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
