import Foundation

/// Explicit per-computer transitions that native resources (terminal surfaces,
/// port forwards, desktop windows, notifications) follow. ConnectionSession
/// emits them synchronously as the stores change, in order, so no intermediate
/// state is coalesced away and no view has to be mounted to observe them.
public enum ConnectionLifecycleEvent: Equatable, Sendable {
    /// Connection generation `previous` ended (disconnect, connect, reconnect
    /// or project replacement). Emitted after per-host state was reset.
    case generationEnded(previous: UUID)
    /// The effective transport changed within a generation (a restarted
    /// helper): streams through `previous` are gone.
    case transportReplaced(previous: String)
    /// `connectionState.isConnected` changed.
    case connectivityChanged
    /// The box list changed; boxes absent or not running were stopped,
    /// removed or evicted.
    case boxesChanged
    /// A lifecycle action began for these boxes.
    case boxActionsBegan(Set<String>)
    /// The selected box's terminal inventory was (re)observed.
    case terminalInventoryChanged(BoxSelectionStore.TerminalInventory)
    /// A complete inventory refresh finished.
    case inventoryRefreshed
    /// The pending approvals changed.
    case approvalsChanged
    /// The computer's saved profile (name, address options) changed.
    case profileChanged
}

/// Registered observers of one session. Handlers run on the main actor in
/// registration order; one registered while an event is delivered sees the
/// next event onward.
@MainActor final class ConnectionLifecycleObservers {
    private var handlers: [(id: UUID, handler: (ConnectionLifecycleEvent) -> Void)] = []
    func add(_ handler: @escaping (ConnectionLifecycleEvent) -> Void) -> UUID {
        let id = UUID(); handlers.append((id, handler)); return id
    }
    func remove(_ id: UUID) { handlers.removeAll { $0.id == id } }
    func emit(_ event: ConnectionLifecycleEvent) {
        for entry in handlers { entry.handler(event) }
    }
}
