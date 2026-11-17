import Foundation
import Testing
@testable import DiscoboxCore

/// Records lifecycle events with the state each handler could see.
@MainActor private final class LifecycleLog {
    var events: [ConnectionLifecycleEvent] = []
    var boxesAtGenerationEnd: [Int] = []
    init(_ session: ConnectionSession) {
        session.observeLifecycle { [unowned self, unowned session] event in
            self.events.append(event)
            if case .generationEnded = event { self.boxesAtGenerationEnd.append(session.inventory.sandboxes.count) }
        }
    }
    func count(_ match: (ConnectionLifecycleEvent) -> Bool) -> Int { events.filter(match).count }
}

private final class SwitchingTransportClient: DiscoboxClient, @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint = "unix:///tmp/first.sock"
    func use(_ value: String) { lock.withLock { endpoint = value } }
    func closeConnection() {}
    func prepareConnection() async throws -> String? { lock.withLock { endpoint } }
    func perform(_ request: BridgeRequest) async throws -> Data { try await DemoClient().perform(request) }
}

@MainActor @Test func generationEndsOnceAfterPerHostStateIsReset() async {
    let session = ConnectionSession(), log = LifecycleLog(session)
    let initial = session.connectionState.connectionID
    await session.connect(client: DemoClient(), label: "Lifecycle fixture", demo: true)
    #expect(log.events.first == .generationEnded(previous: initial))
    #expect(log.count { $0 == .connectivityChanged } == 1)
    #expect(log.count { $0 == .boxesChanged } >= 1)
    #expect(log.count { $0 == .inventoryRefreshed } == 1)
    let connected = session.connectionState.connectionID
    log.events.removeAll()
    session.disconnect()
    #expect(log.events.filter { if case .generationEnded = $0 { true } else { false } } == [.generationEnded(previous: connected)])
    // Emitted last, so handlers see the reset state.
    #expect(log.events.last == .generationEnded(previous: connected))
    #expect(log.boxesAtGenerationEnd.last == 0)
    #expect(log.events.contains(.connectivityChanged))
    #expect(log.events.contains(.boxesChanged))
}

@MainActor @Test func boxActionBeginningIsReportedEvenWhenItFinishesImmediately() async throws {
    let session = ConnectionSession(), log = LifecycleLog(session)
    await session.connect(client: DemoClient(), label: "Lifecycle fixture", demo: true)
    log.events.removeAll()
    try await session.commands.performBoxAction(.stop, boxID: "demo-ui", connection: session.connectionState.connectionID)
    #expect(session.pending.pendingBoxActions.isEmpty)
    #expect(log.events.first == .boxActionsBegan(["demo-ui"]))
    #expect(log.count { $0 == .boxActionsBegan(["demo-ui"]) } == 1)
}

@MainActor @Test func transportReplacementWithinAGenerationIsReported() async {
    let client = SwitchingTransportClient(), session = ConnectionSession(), log = LifecycleLog(session)
    await session.connect(client: client, label: "discobox://fixture")
    let generation = session.connectionState.connectionID
    // The label is replaced by the helper's socket during the first connect.
    #expect(log.events.contains(.transportReplaced(previous: "discobox://fixture")))
    log.events.removeAll()
    await session.refresh()
    #expect(!log.events.contains { if case .transportReplaced = $0 { true } else { false } })
    client.use("unix:///tmp/second.sock")
    await session.refresh()
    #expect(log.events.contains(.transportReplaced(previous: "unix:///tmp/first.sock")))
    #expect(session.connectionState.connectionID == generation)
    session.disconnect()
}

@MainActor @Test func selectionApprovalsAndProfileChangesAreReported() async {
    let client = DemoClient(pendingRequests: true), session = ConnectionSession(), log = LifecycleLog(session)
    await session.connect(client: client, label: "Lifecycle fixture", demo: true)
    log.events.removeAll()
    await session.selection.selectBox("demo-ui")
    #expect(log.events.contains { if case .terminalInventoryChanged(let inventory) = $0 { inventory.box == "demo-ui" } else { false } })
    await session.approvalStore.refreshApprovals()
    #expect(log.count { $0 == .approvalsChanged } == 1)
    await session.approvalStore.refreshApprovals()
    #expect(log.count { $0 == .approvalsChanged } == 1)
    session.update(.init(name: "Renamed", endpoint: session.profile.endpoint))
    session.update(.init(name: "Renamed", endpoint: session.profile.endpoint))
    #expect(log.count { $0 == .profileChanged } == 1)
    session.disconnect()
}

@MainActor @Test func removedLifecycleObserversAreNotCalled() async {
    let session = ConnectionSession()
    var calls = 0
    let id = session.observeLifecycle { _ in calls += 1 }
    session.removeLifecycleObserver(id)
    await session.connect(client: DemoClient(), label: "Lifecycle fixture", demo: true)
    session.disconnect()
    #expect(calls == 0)
}
