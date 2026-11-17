import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func oneAndManyComputerSwitchersUseTheSameDeterministicPolicy() async throws {
    let hub = Connections(polling: false)
    let local = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
    let single = hub.switcherBoxes.map(\.location.box)
    let remote = try await hub.connect(.init(name: "Second", endpoint: "https://second.example.invalid"), demo: true) { DemoClient() }
    #expect(hub.switcherBoxes.filter { $0.location.connection == local.id }.map(\.location.box) == single)
    #expect(hub.switcherBoxes.filter { $0.location.connection == remote.id }.map(\.location.box) == single)
    let browser = BoxBrowser()
    #expect(browser.switcherBoxes(in: hub.qualifiedBoxes.reversed()).map(\.id) == hub.switcherBoxes.map(\.id))
    let running = try #require(hub.switcherBoxes.first { $0.power.isRunning })
    let stale = ConnectedBox(location: running.location, computer: running.computer, box: running.box,
        needsAttention: false, power: BoxPowerStatus(box: running.box, reachable: false))
    #expect(BoxBrowser.switcherGroup(stale).title == "Status unknown")
    hub.disconnectAll()
}

private actor PollTicks {
    private var waiting: [ConnectionSession.Poll: [CheckedContinuation<Void, Never>]] = [:]
    func sleep(_ kind: ConnectionSession.Poll) async {
        await withCheckedContinuation { waiting[kind, default: []].append($0) }
    }
    func waitForAll() async {
        while waiting.values.reduce(0, { $0 + $1.count }) != 4 { await Task.yield() }
    }
    func release(_ kind: ConnectionSession.Poll) { waiting.removeValue(forKey: kind)?.forEach { $0.resume() } }
    func releaseAll() { let values = waiting.values.flatMap { $0 }; waiting.removeAll(); values.forEach { $0.resume() } }
    var count: Int { waiting.values.reduce(0, { $0 + $1.count }) }
}

private actor SessionRecordingClient: DiscoboxClient {
    let demo = DemoClient()
    private(set) var requests: [BridgeRequest] = []
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request)
        if request.operation == .approvalContext { return Data(#"{"fingerprint":"fixture"}"#.utf8) }
        return try await demo.perform(request)
    }
    func count(_ operation: BridgeRequest.Operation) -> Int { requests.filter { $0.operation == operation }.count }
}

@MainActor @Test func oneSessionOwnsPollingAndDisconnectStopsFurtherReads() async throws {
    let ticks = PollTicks(), client = SessionRecordingClient(), hub = Connections()
    hub.active.pollSleep = { kind, _ in await ticks.sleep(kind); try Task.checkCancellation() }
    let session = try await hub.connect(.thisComputer, demo: true) { client }
    await ticks.waitForAll()
    #expect(await client.count(.approvals) == 1)
    _ = try await hub.connect(.thisComputer, demo: true) { client }
    #expect(await ticks.count == 4)
    await ticks.release(.approvals)
    await ticks.waitForAll()
    #expect(await client.count(.approvals) == 2)
    hub.disconnect(session.id)
    let before = await client.requests.count
    await ticks.releaseAll()
    for _ in 0..<20 { await Task.yield() }
    #expect(await client.requests.count == before)
}

@MainActor @Test func idlePollingDoesNotRetainItsSession() async {
    let ticks = PollTicks()
    var session: ConnectionSession? = ConnectionSession()
    weak let observed = session
    session?.pollSleep = { kind, _ in await ticks.sleep(kind); try Task.checkCancellation() }
    await session?.connect(client: DemoClient(), label: "fixture", demo: true)
    session?.startPolling()
    await ticks.waitForAll()
    session = nil
    #expect(observed == nil)
    await ticks.releaseAll()
}

@MainActor @Test func approvalContextUsesRequestingBoxInsteadOfVisibleSelection() async throws {
    let session = ConnectionSession(), client = SessionRecordingClient()
    await session.connect(client: client, label: "fixture", demo: true)
    let item = ApprovalItem(kind: "credential", credential: .object(["id": .string("request"), "sandboxId": .string("demo-ui"), "status": .string("pending")]))
    await session.selection.selectBox("demo-api")
    _ = try await session.approvalStore.context(item: item, payload: nil)
    let request = try #require(await client.requests.last { $0.operation == .approvalContext })
    #expect(request.sandboxID == item.boxID)
    #expect(request.projectID == session.connectionState.projectID)
    session.disconnect()
}
