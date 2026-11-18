import Foundation
import Testing
@testable import DiscoboxCore

private func change(_ id: Int64, box: String = "demo-ui", project: String = "demo",
                    type: String = "sandbox.updated", state: String = "running") -> ProjectEventFrame {
    .init(version: 1, kind: .event, id: id, type: type,
          data: .init(projectId: project, sandboxId: box, name: "handle", state: "ready", displayState: state,
                      runtimeState: state, errorMessage: nil, tags: ["topic": "design"],
                      program: .init(state: "working", kind: nil)), retry: nil)
}

private func control(_ kind: ProjectEventFrame.Kind, _ id: Int64? = nil) -> ProjectEventFrame {
    .init(version: 1, kind: kind, id: id, type: nil, data: nil, retry: nil)
}

@MainActor @Test func replayAppliesAtCheckpointAndIgnoresDuplicatesAndForeignProjects() throws {
    let store = BoxInventoryStore()
    var replay = ProjectEventReplay()
    func accept(_ frame: ProjectEventFrame) throws {
        _ = store.apply([try replay.accept(frame, project: "demo")])
    }
    try accept(change(10))
    #expect(replay.cursor == nil && store.sandboxes.isEmpty)
    try accept(control(.checkpoint, 10))
    #expect(replay.cursor == 10 && store.sandboxes.count == 1)
    try accept(change(9, type: "sandbox.deleted"))
    try accept(change(10, type: "sandbox.deleted"))
    #expect(store.sandboxes.count == 1)
    #expect(throws: DiscoboxError.self) { try accept(change(11, project: "other")) }
    #expect(replay.cursor == 10)
    try accept(control(.reset))
    try accept(change(2, box: "replacement"))
    #expect(store.replayingReset && store.sandboxes.first?.id == "demo-ui")
    replay.interrupted()
    #expect(replay.cursor == nil)
    try accept(control(.checkpoint, 3))
    #expect(!store.replayingReset && store.sandboxes.isEmpty && replay.cursor == 3)
}

@MainActor @Test func unrelatedLiveEventsPreserveAnAcknowledgedCreationUntilItsEventArrives() throws {
    let store = BoxInventoryStore()
    _ = store.apply([.replace([:])])
    let created = try #require(change(1, box: "new").data)
    store.includeCreated(created.applying(to: nil))
    let other = try #require(change(2, box: "other").data)
    _ = store.apply([.update(other)])
    #expect(Set(store.sandboxes.map(\.id)) == ["new", "other"])
    _ = store.apply([.update(created)])
    #expect(store.sandboxes.filter { $0.id == "new" }.count == 1)
    _ = store.apply([.delete("new")])
    #expect(store.sandboxes.map(\.id) == ["other"])
}

private actor EventFixture: DiscoboxClient, ProjectEventSource {
    private let demo = DemoClient()
    private(set) var subscriptions = 0
    private(set) var requests: [BridgeRequest.Operation] = []
    private var deliver: ProjectEventReceiver?
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request.operation)
        return try await demo.perform(request)
    }
    func readEvents(endpoint: String, project: String, generation: UUID, after: Int64?, receive: @escaping ProjectEventReceiver) async throws {
        subscriptions += 1
        deliver = receive
        try await Task.sleep(for: .seconds(3600))
    }
    func send(_ frames: [ProjectEventFrame]) async throws {
        for _ in 0..<1000 where deliver == nil { await Task.yield() }
        let receiver = try #require(deliver)
        try await receiver(frames)
    }
}

@MainActor @Test func projectEventsUpdateSelectedBoxWithoutGuestReadsAndProtectAgainstLateLists() async throws {
    let session = ConnectionSession(), client = EventFixture()
    await session.connect(client: client, label: "fixture")
    defer { session.disconnect() }
    await session.selection.selectBox("demo-ui")
    var settings = RefreshPolicy()
    settings.manual = true
    session.applyRefreshPolicy(settings)
    let before = await client.requests
    let title = try #require(session.inventory.sandboxes.first(where: { $0.id == "demo-ui" })).displayName
    try await client.send([change(1), control(.checkpoint, 1)])
    let box = try #require(session.inventory.sandboxes.first)
    #expect(box.displayName == title && box.poolId == "local" && box.meta?.tags?["topic"] == "design")
    #expect(AgentActivity(box: box).isWorking)
    try await client.send([change(2, state: "stopped")])
    #expect(session.selection.selectedBox?.isRunning == false)
    try await client.send([change(3, type: "sandbox.deleted")])
    #expect(session.selection.sandboxID == nil && session.inventory.sandboxes.isEmpty)
    let after = await client.requests
    for op in [BridgeRequest.Operation.execs, .services, .sandboxes] {
        #expect(before.filter { $0 == op }.count == after.filter { $0 == op }.count)
    }
    // The list still contains the old box. The event tombstone wins.
    await session.refresh()
    #expect(session.inventory.sandboxes.isEmpty && session.eventsCurrent)
    #expect(await client.subscriptions == 1)
    session.disconnect()
    await #expect(throws: CancellationError.self) { try await client.send([change(4)]) }
}
