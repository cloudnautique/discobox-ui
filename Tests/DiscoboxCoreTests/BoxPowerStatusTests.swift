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
    await host.workspace.refresh()
    #expect(hub.browserBoxes.isEmpty)
    #expect(hub.switcherBoxes.allSatisfy { !$0.power.isCurrent })
    hub.browser.filter = .all
    #expect(!hub.browserBoxes.isEmpty) // Retain unknown boxes for inspection.
    await client.setReport(Date.now.ISO8601Format())
    await host.workspace.refresh()
    #expect(hub.switcherBoxes.allSatisfy { $0.power.isCurrent })
    await client.goOffline()
    await host.workspace.refresh()
    #expect(hub.switcherBoxes.allSatisfy { !$0.power.isCurrent })
    #expect(hub.switcherBoxes.allSatisfy { BoxIndicator(box: $0.box, activity: $0.activity!, power: $0.power).state == .unavailable })
    hub.browser.filter = .running
    #expect(hub.browserBoxes.isEmpty)
}

@MainActor @Test func retainedTerminalCannotAttachToADifferentWorkspacesInventory() async throws {
    let workspace = Workspace()
    await workspace.connect(client: DemoClient(), label: "Fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.selectBox("demo-ui")
    let live = try #require(workspace.execs.first { $0.acceptsInput })
    #expect(workspace.canAttachTerminal(live))
    let foreign = try JSONDecoder().decode(Exec.self, from: Data(#"{"id":"other-host-exec","status":"running","command":["sh"],"workdir":"/","tty":true}"#.utf8))
    #expect(!workspace.canAttachTerminal(foreign))
    await workspace.selectBox("demo-api")
    #expect(!workspace.canAttachTerminal(live))
}

private actor PowerInventoryFixture: DiscoboxClient {
    let demo = DemoClient()
    var report = Date.now.ISO8601Format()
    var online = true
    func setReport(_ value: String) { report = value }
    func goOffline() { online = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
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
