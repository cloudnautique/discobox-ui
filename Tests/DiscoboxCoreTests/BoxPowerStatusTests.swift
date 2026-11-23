import Foundation
import Testing
@testable import DiscoboxCore

private let powerNow = Date(timeIntervalSince1970: 1_800_000_000)

private func powerBox(display: String = "running", reported: String? = nil) throws -> Sandbox {
    var runtime: [String: JSONValue] = ["state": .string("ready"), "runtimeState": .string("running"), "displayState": .string(display),
        "agentStatus": .object(["sessions": .array([.object(["primary": .bool(true), "execStatus": .string("running"), "programStatus": .object(["state": .string("working")])])])])]
    if let reported { runtime["stateReportedAt"] = .string(reported) }
    return try JSONDecoder().decode(Sandbox.self, from: JSONEncoder().encode(JSONValue.object([
        "id": .string("box"), "projectId": .string("p"), "displayName": .string("Box"), "config": .object([:]), "runtime": .object(runtime)
    ])))
}

@Test func oldPowerReportsCannotKeepGreenLightsOrWorkingActivity() throws {
    for report in [powerNow.addingTimeInterval(-121).ISO8601Format(), powerNow.addingTimeInterval(121).ISO8601Format(), "invalid", ""] {
        let box = try powerBox(reported: report)
        let power = BoxPowerStatus(box: box, now: powerNow)
        let activity = AgentActivity(box: box, now: powerNow)
        #expect(!power.isCurrent && !power.isRunning && power.label == "Status unknown")
        #expect(box.isRunning) // Preserve the server value; do not invent Stopped.
        #expect(!activity.isWorking)
        #expect(BoxIndicator(box: box, activity: activity, power: power).state == .unavailable)
    }
    for report in [nil, powerNow.ISO8601Format(), powerNow.addingTimeInterval(-60).ISO8601Format()] {
        let box = try powerBox(reported: report)
        let power = BoxPowerStatus(box: box, now: powerNow)
        #expect(power.isCurrent && power.isRunning)
        #expect(BoxIndicator(box: box, activity: .init(box: box, now: powerNow), power: power).state == .on)
    }
}

@Test func composedPowerStateWinsOverOldRuntimeAndAgentFields() throws {
    for display in ["stopped", "stopping", "starting", "archived", "deleted", "repairing"] {
        let box = try powerBox(display: display, reported: powerNow.ISO8601Format())
        let power = BoxPowerStatus(box: box, now: powerNow)
        #expect(!power.isRunning)
        #expect(!AgentActivity(box: box, now: powerNow).isWorking)
        #expect(BoxIndicator(box: box, activity: .init(box: box, now: powerNow), power: power).state != .on)
    }
}

@MainActor @Test func sidebarAndSwitcherDoNotTreatCachedRunningBoxesAsConfirmed() async throws {
    let hub = Connections(polling: false), client = PowerInventoryFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    #expect(!hub.browserBoxes.isEmpty)
    await client.setReport(Date.now.addingTimeInterval(-180).ISO8601Format())
    await host.refresh()
    #expect(hub.browserBoxes.isEmpty)
    #expect(hub.switcherBoxes.allSatisfy { !$0.power.isCurrent })
    hub.browser.filter = .all
    #expect(!hub.browserBoxes.isEmpty) // Retain unknown boxes for inspection.
    await client.setReport(Date.now.ISO8601Format())
    await host.refresh()
    #expect(hub.switcherBoxes.allSatisfy { $0.power.isCurrent })
    await client.goOffline()
    await host.refresh()
    #expect(hub.switcherBoxes.allSatisfy { !$0.power.isCurrent })
    #expect(hub.switcherBoxes.allSatisfy { BoxIndicator(box: $0.box, activity: $0.activity!, power: $0.power).state == .unavailable })
    hub.browser.filter = .running
    #expect(hub.browserBoxes.isEmpty)
}

@MainActor @Test func retainedTerminalCannotAttachToADifferentWorkspacesInventory() async throws {
    let workspace = ConnectionSession()
    await workspace.connect(client: DemoClient(), label: "Fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.selection.selectBox("demo-ui")
    let live = try #require(workspace.selection.execs.first { $0.acceptsInput })
    #expect(workspace.selection.canAttachTerminal(live))
    let foreign = try JSONDecoder().decode(Exec.self, from: Data(#"{"id":"other-host-exec","status":"running","command":["sh"],"workdir":"/","tty":true}"#.utf8))
    #expect(!workspace.selection.canAttachTerminal(foreign))
    await workspace.selection.selectBox("demo-api")
    #expect(!workspace.selection.canAttachTerminal(live))
}

@MainActor @Test func runningAcrossComputersReconcilesRemotePowerWhileKeepingTheOpenTerminal() async throws {
    var now = Date()
    let hub = Connections(now: { now })
    let laptop = ConnectionProfile(name: "Laptop", endpoint: "https://laptop.invalid")
    hub.syncProfiles([laptop])
    for host in hub.sessions {
        host.pollSleep = { _, _ in try await Task.sleep(for: .seconds(3600)) }
    }
    let local = try await hub.connect(.thisComputer, demo: true) { PowerInventoryFixture() }
    defer { hub.disconnectAll() }
    await hub.selectBox(.init(connection: local.id, box: "demo-ui"))
    let client = PowerInventoryFixture()
    await client.setReport(Date.now.addingTimeInterval(-180).ISO8601Format())
    let remote = try await hub.connect(laptop, demo: true, select: false) { client }
    await remote.selection.selectBox("demo-ui")
    try await client.confirmRunning()
    try #require(remote.eventsCurrent)
    let terminal = try #require(local.selection.execID)
    let originalReads = await client.counts
    #expect(remote.cadence.eventInventoryInterval == 15)

    // The pool confirms the same running state. No new project event is emitted.
    await client.setReport(Date.now.ISO8601Format())
    func expectBothComputers() async throws {
        let limit = ContinuousClock.now + .seconds(3)
        while !hub.browserBoxes.contains(where: { $0.location.connection == remote.id }) && ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(hub.browserBoxes.map(\.location.connection)) == [local.id, remote.id])
    }
    hub.browser.filter = .running
    try await expectBothComputers()
    #expect(remote.cadence.eventInventoryInterval == 15)
    let refreshed = await client.counts
    #expect(refreshed[.sandboxes, default: 0] == originalReads[.sandboxes, default: 0] + 1)
    #expect(refreshed[.execs] == originalReads[.execs] && refreshed[.services] == originalReads[.services])

    hub.refreshPolicy.manual = true
    await client.setReport(Date.now.addingTimeInterval(-180).ISO8601Format())
    await hub.refreshWorkspace()
    #expect(Set(hub.browserBoxes.map(\.location.connection)) == [local.id])
    let manualReads = await client.counts
    #expect(manualReads[.sandboxes, default: 0] == refreshed[.sandboxes, default: 0] + 1)
    #expect(manualReads[.execs] == refreshed[.execs] && manualReads[.services] == refreshed[.services])
    hub.browser.computerID = local.id
    #expect(remote.cadence.eventInventoryInterval == 300)
    hub.refreshPolicy.manual = false
    await client.setReport(Date.now.ISO8601Format())
    now += 6
    hub.browser.computerID = nil
    try await expectBothComputers()
    #expect(hub.activeID == local.id && local.selection.execID == terminal)
    hub.presence = .hidden
    #expect(remote.cadence.eventInventoryInterval == 300)
}

@MainActor @Test func allComputersPublishesFastInventoryWhileAnotherHostIsBlocked() async throws {
    var now = Date()
    let hub = Connections(now: { now })
    let laptop = ConnectionProfile(name: "Laptop", endpoint: "https://laptop.invalid")
    hub.syncProfiles([laptop])
    for host in hub.sessions { host.pollSleep = { _, _ in try await Task.sleep(for: .seconds(3600)) } }
    let fast = PowerInventoryFixture(), slow = PowerInventoryFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { fast }
    defer { hub.disconnectAll() }
    let remote = try await hub.connect(laptop, demo: true, select: false) { slow }
    await hub.selectBox(.init(connection: local.id, box: "demo-ui"))
    let terminal = try #require(local.selection.execID)
    hub.browser.computerID = local.id
    let before = await slow.counts
    await slow.holdNext(.sandboxes)
    now += 6
    hub.browser.showAllComputers()
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if local.inventory.boxesObservedAt == now, await slow.requestHeld { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(local.inventory.boxesObservedAt == now)
    #expect(remote.inventory.boxesObservedAt != now)
    #expect(await slow.requestHeld)
    #expect(hub.activeID == local.id && local.selection.execID == terminal)
    let fastReads = await fast.counts[.sandboxes, default: 0]
    hub.browser.showAllComputers()
    let manual = Task { await hub.refreshWorkspace() }
    let manualDeadline = ContinuousClock.now + .seconds(3)
    while await fast.counts[.sandboxes, default: 0] == fastReads && ContinuousClock.now < manualDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fast.counts[.sandboxes, default: 0] == fastReads + 1)
    await slow.releaseRequest()
    await manual.value
    #expect(remote.inventory.boxesObservedAt == now)
    let after = await slow.counts
    #expect(after[.sandboxes, default: 0] == before[.sandboxes, default: 0] + 1)
    #expect(after[.execs] == before[.execs] && after[.services] == before[.services])
}

@MainActor @Test func visibleUsageUpdatesWhileAnotherComputerIsWaiting() async throws {
    let hub = Connections(), window = UUID()
    defer { hub.disconnectAll() }
    hub.reportPresence(.focused, from: window)
    hub.reportUsageSurface(visible: true, from: window)
    let slow = PowerInventoryFixture()
    await slow.holdNext(.usage)
    let local = try await hub.connect(.thisComputer, demo: true) { slow }
    let deadline = ContinuousClock.now + .seconds(3)
    while await !slow.requestHeld && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await slow.requestHeld)
    let remote = try await hub.connect(.init(name: "Laptop", endpoint: "https://laptop.invalid"), demo: true,
                                       select: false) { PowerInventoryFixture() }
    let remoteDeadline = ContinuousClock.now + .seconds(3)
    while remote.usage.snapshots.isEmpty && ContinuousClock.now < remoteDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!remote.usage.snapshots.isEmpty)
    #expect(local.usage.isLoading && local.usage.snapshots.isEmpty)
    await slow.releaseRequest()
}

private actor PowerInventoryFixture: DiscoboxClient, ProjectEventSource {
    let demo = DemoClient()
    var report = Date.now.ISO8601Format()
    var online = true
    private var heldOperation: BridgeRequest.Operation?
    private var waiting: CheckedContinuation<Void, Never>?
    var requestHeld: Bool { waiting != nil }
    func holdNext(_ operation: BridgeRequest.Operation) { heldOperation = operation }
    func releaseRequest() { heldOperation = nil; waiting?.resume(); waiting = nil }
    private(set) var counts: [BridgeRequest.Operation: Int] = [:]
    private var receiveEvents: ProjectEventReceiver?
    func readEvents(endpoint: String, project: String, generation: UUID, after: Int64?, receive: @escaping ProjectEventReceiver) async throws {
        receiveEvents = receive
        try await Task.sleep(for: .seconds(3600))
    }
    func confirmRunning() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while receiveEvents == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let receive = try #require(receiveEvents)
        let box = ProjectBoxEvent(projectId: "demo", sandboxId: "demo-ui", name: "Fixture", state: "ready",
                                  displayState: "running", runtimeState: "running", errorMessage: nil, tags: nil, program: nil)
        try await receive([.init(version: 1, kind: .event, id: 1, type: "sandbox.updated", data: box, retry: nil),
                           .init(version: 1, kind: .checkpoint, id: 1, type: nil, data: nil, retry: nil)])
    }
    func setReport(_ value: String) { report = value }
    func goOffline() { online = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
        counts[request.operation, default: 0] += 1
        if request.operation == heldOperation {
            heldOperation = nil
            await withCheckedContinuation { waiting = $0 }
        }
        guard online else { throw URLError(.networkConnectionLost) }
        let data = try await demo.perform(request)
        guard request.operation == .sandboxes else { return data }
        var body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var boxes = try #require(body["sandboxes"] as? [[String: Any]])
        for index in boxes.indices {
            var runtime = try #require(boxes[index]["runtime"] as? [String: Any])
            runtime["stateReportedAt"] = report
            boxes[index]["runtime"] = runtime
        }
        body["sandboxes"] = boxes
        return try JSONSerialization.data(withJSONObject: body)
    }
}
