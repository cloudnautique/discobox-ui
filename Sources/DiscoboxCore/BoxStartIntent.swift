import Foundation
import Observation

/// An explicit start keeps its original computer, box and connection even if
/// the user changes selection while a prompt or request is open.
@MainActor @Observable public final class BoxStartIntent {
    public let workspace: Workspace
    public let box: Sandbox
    public let computer: String
    public let connection: UUID
    public private(set) var working = false
    public private(set) var failure: String?

    public init(workspace: Workspace, box: Sandbox, computer: String) {
        self.workspace = workspace; self.box = box; self.computer = computer
        connection = workspace.connectionID
    }
    public var isCurrent: Bool {
        workspace.isConnected && workspace.connectionID == connection && currentBox != nil
    }
    public var currentBox: Sandbox? { workspace.sandboxes.first { $0.id == box.id && !$0.isArchived } }
    public var canStart: Bool {
        isCurrent && !working && !workspace.pendingBoxActions.contains(box.id) &&
        !workspace.clearingPools.contains(currentBox?.poolId ?? "") &&
        currentBox.map { $0.isRunning || BoxAction.start.isAvailable(for: $0) } == true
    }
    public var alreadyRunning: Bool { isCurrent && currentBox?.isRunning == true }

    /// No retries: a failed or ambiguous request remains an explicit user choice.
    public func start() async -> Bool {
        guard !working else { return false }
        guard isCurrent else {
            failure = "This computer disconnected, reconnected, or no longer has the box. Choose it again."
            return false
        }
        if alreadyRunning { failure = nil; return true }
        working = true; failure = nil
        defer { working = false }
        do {
            try await workspace.performBoxAction(.start, boxID: box.id, connection: connection)
            guard isCurrent else { throw DiscoboxError("The computer’s connection changed while starting. Check the box’s current state before trying again.") }
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}
