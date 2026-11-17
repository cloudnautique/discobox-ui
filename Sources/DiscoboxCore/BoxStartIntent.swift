import Foundation
import Observation

/// An explicit start keeps its original computer, box and connection even if
/// the user changes selection while a prompt or request is open.
@MainActor @Observable public final class BoxStartIntent {
    private let connectionState: ConnectionStore
    private let inventory: BoxInventoryStore
    private let pending: PendingBoxOperations
    private let commands: BoxCommands
    public let box: Sandbox
    public let computer: String
    public let connection: UUID
    public private(set) var working = false
    public private(set) var failure: String?

    public init(connection: ConnectionStore, inventory: BoxInventoryStore, pending: PendingBoxOperations, commands: BoxCommands, box: Sandbox, computer: String) {
        self.connectionState = connection; self.inventory = inventory; self.pending = pending; self.commands = commands
        self.box = box; self.computer = computer; self.connection = connection.connectionID
    }
    public var isCurrent: Bool {
        connectionState.isConnected && connectionState.connectionID == connection && currentBox != nil
    }
    public var currentBox: Sandbox? { inventory.sandboxes.first { $0.id == box.id && !$0.isArchived } }
    public var canStart: Bool {
        isCurrent && !working && !pending.pendingBoxActions.contains(box.id) &&
        !pending.clearingPools.contains(currentBox?.poolId ?? "") &&
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
            try await commands.performBoxAction(.start, boxID: box.id, connection: connection)
            guard isCurrent else { throw DiscoboxError("The computer’s connection changed while starting. Check the box’s current state before trying again.") }
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}
