import Foundation
import Testing
@testable import DiscoboxCore

private let activityNow = Date(timeIntervalSince1970: 1_800_000_000)
private func sampleBox(_ state: String? = "working", kind: String = "", runtime: String = "running", observed: Date? = activityNow, sessions: [JSONValue]? = nil, name: String? = nil) throws -> Sandbox {
    var agent: [String: JSONValue] = ["sessions": .array(sessions ?? [session(state, kind: kind)])]
    if let observed { agent["observedAt"] = .string(observed.ISO8601Format()) }
    var fields: [String: JSONValue] = [
        "id": .string("box"), "projectId": .string("project"), "displayName": .string("Task: run tests"),
        "config": .object(["name": .string("Task")]),
        "runtime": .object(["state": .string(runtime == "archived" ? "archived" : "ready"), "runtimeState": .string(runtime), "agentStatus": .object(agent)])
    ]
    if let name { fields["meta"] = .object(["name": .string(name)]) }
    return try JSONDecoder().decode(Sandbox.self, from: JSONEncoder().encode(JSONValue.object(fields)))
}
private func session(_ state: String?, kind: String = "", primary: Bool = true, started: String = "2026-01-01T00:00:00Z", title: String = "Task", message: String = "run tests", process: String = "running") -> JSONValue {
    var fields: [String: JSONValue] = ["primary": .bool(primary), "startedAt": .string(started), "execStatus": .string(process), "title": .string(title)]
    if let state { fields["programStatus"] = .object(["state": .string(state), "kind": .string(kind), "msg": .string(message), "reportedAt": .string("2020-01-01T00:00:00Z")]) }
    return .object(fields)
}

@Test func reportedActivityDistinguishesAgentWorkFromContainerPowerAndHumanDecisions() throws {
    let cases: [(String, String, AgentActivity.State, Bool)] = [
        ("working", "", .working, false), ("idle", "", .idle, false), ("done", "", .finished, false),
        ("error", "", .failed, true), ("blocked", "permission", .approval, true),
        ("blocked", "question", .question, true), ("blocked", "auth", .signIn, true), ("blocked", "future-kind", .blocked, true)
    ]
    for (state, kind, expected, attention) in cases {
        let box = try sampleBox(state, kind: kind), activity = AgentActivity(box: box, now: activityNow)
        #expect(box.isRunning)
        #expect(activity.state == expected && activity.needsYou == attention)
        #expect(activity.isWorking == (expected == .working))
    }
    let box = try sampleBox("idle")
    let waiting = AgentActivity(box: box, pendingRequests: 3, now: activityNow)
    #expect(waiting.state == .approval && waiting.approvalCount == 3 && !waiting.isWorking)
}

@Test func activityUsesNewestPrimaryAndNeverGuessesFromTitleOrOtherTerminals() throws {
    let old = session("working"), newer = session(nil, started: "2026-01-02T00:00:00.100Z", title: "Working hard")
    let shell = session("working", primary: false, started: "2026-01-03T00:00:00Z")
    for latest in [newer, session("future-state", started: "2026-01-02T00:00:00Z"), session("working", started: "2026-01-02T00:00:00Z", process: "exited")] {
        let box = try sampleBox(sessions: [old, shell, latest])
        #expect(AgentActivity(box: box, now: activityNow).state == .unavailable)
    }
    let box = try sampleBox(sessions: [old, session("blocked", kind: "question", started: "2026-01-02T00:00:00Z"), shell])
    #expect(AgentActivity(box: box, now: activityNow).state == .question)
    let ended = try sampleBox(sessions: [session("done", process: "exited")])
    #expect(AgentActivity(box: ended, now: activityNow).state == .finished)
}

@Test func staleSnapshotsAndDisconnectedHostsDoNotAdvertiseLiveActivity() throws {
    for state in ["working", "blocked", "idle"] {
        let stale = try sampleBox(state, observed: activityNow.addingTimeInterval(-121))
        #expect(AgentActivity(box: stale, now: activityNow).state == .unavailable)
        let live = try sampleBox(state)
        #expect(AgentActivity(box: live, reachable: false, now: activityNow).state == .unavailable)
    }
    // Fresh container snapshots can legitimately hold an unchanged report for days.
    #expect(AgentActivity(box: try sampleBox("idle"), now: activityNow).state == .idle)
    #expect(AgentActivity(box: try sampleBox("working", observed: nil), now: activityNow).isWorking)
    for runtime in ["stopped", "archived"] {
        #expect(AgentActivity(box: try sampleBox(runtime: runtime), now: activityNow).state == .inactive)
    }
}

@Test func sidebarTitleKeepsNamesAndSeparatesReportedMessagesWithoutSplittingColons() throws {
    #expect(try sampleBox(name: "API: Authorization: audit").sidebarTitle == "API: Authorization: audit")
    #expect(try sampleBox().sidebarTitle == "Task")
    #expect(try sampleBox(sessions: [session("working", title: "", message: "run tests")]).sidebarTitle == "Task")
    #expect(try sampleBox(sessions: [session("working", title: "", message: "unrelated")]).sidebarTitle == "Task: run tests")
    let box = try sampleBox(sessions: [session("working", title: "safe\u{202e}title\u{0007}", message: "plain\u{001b}text")])
    #expect(box.sidebarTitle == "safetitle")
    #expect(AgentActivity(box: box, now: activityNow).message == "plaintext")
}

@MainActor @Test func activityFiltersCountBoxesWithinHostTagAndSearchScopeWithoutExtraRequests() async throws {
    let hub = Connections(polling: false), a = ActivityBrowserFixture(), b = ActivityBrowserFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { a }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://remote.example.invalid"), demo: true) { b }
    defer { hub.disconnectAll() }
    await local.workspace.refreshApprovals(); await remote.workspace.refreshApprovals()
    _ = try await local.workspace.harnesses(); _ = try await remote.workspace.harnesses()
    #expect(hub.browserCandidates.filter(\.needsAttention).count == 4)
    #expect(hub.browserCandidates.filter { $0.activity?.isWorking == true }.count == 2)
    let reads = await a.reads + b.reads
    hub.browser.activityFilter = .needsYou
    #expect(hub.browserBoxes.count == 4)
    #expect(hub.browserCandidates.count == 8)
    hub.browser.activityFilter = .working
    #expect(hub.browserBoxes.count == 2)
    hub.browser.computerID = remote.id
    #expect(hub.browserBoxes.map(\.box.id) == ["work"])
    hub.browser.activityFilter = .needsYou
    hub.browser.selectedTags = ["team=api"]
    #expect(hub.browserBoxes.map(\.box.id) == ["approval"])
    #expect(hub.browserCandidates.filter(\.needsAttention).count == 1) // two requests, one box
    hub.browser.searchText = "nonexistent"
    #expect(hub.browserBoxes.isEmpty && hub.browserCandidates.isEmpty)
    #expect(await a.reads + b.reads == reads)
}

@MainActor @Test func activityChangesKeepSelectionVisibleAndRowsStableWithoutInflatingResults() async throws {
    let hub = Connections(polling: false), client = ActivityBrowserFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    let location = BoxLocation(connection: host.id, box: "work")
    await hub.selectBox(location)
    let order = hub.browserCandidates.map(\.location)
    hub.browser.activityFilter = .working
    #expect(hub.browserSelectionPin == nil && hub.browserBoxes.map(\.box.id) == ["work"])
    await client.finishWork(); await host.workspace.refresh()
    #expect(hub.browserBoxes.isEmpty)
    #expect(hub.browserSelectionPin?.location == location)
    #expect(host.workspace.sandboxID == "work" && hub.browser.activityFilter == .working)
    #expect(hub.browserCandidates.map(\.location) == order)
    hub.browser.searchText = "Answer"
    #expect(hub.browserSelectionPin == nil) // explicit search still owns the scope
    hub.browser.searchText = ""; hub.browser.activityFilter = nil
    #expect(hub.browserBoxes.count == 4 && hub.browserSelectionPin == nil)
}

@MainActor @Test func archivesIgnoreQuickActivityAndExplicitCreationRevealClearsOnlyConflictingFilters() async throws {
    let hub = Connections(polling: false)
    let host = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
    defer { hub.disconnectAll() }
    try await host.workspace.performBoxAction(.archive, boxID: "demo-api", connection: host.workspace.connectionID)
    hub.browser.activityFilter = .working; hub.browser.filter = .archived
    #expect(hub.browserBoxes.map(\.box.id) == ["demo-api"] && hub.browserSelectionPin == nil)
    hub.browser.filter = .all
    try await hub.createBox(on: host.id, harness: "demo-harness", repository: "")
    let creation = try #require(hub.creationPins.first)
    #expect(hub.browser.activityFilter == .working)
    await hub.revealCreatedBox(creation.id)
    #expect(hub.browser.activityFilter == nil)
    #expect(host.workspace.sandboxID == creation.id.box)
}

private actor ActivityBrowserFixture: DiscoboxClient {
    let demo = DemoClient()
    private var finished = false
    private(set) var reads = 0
    func finishWork() { finished = true }
    func perform(_ request: BridgeRequest) async throws -> Data {
        reads += 1
        if request.operation == .sandboxes {
            let definitions = [("work", "A Work", finished ? "done" : "working", "api"), ("approval", "B Approval", "idle", "api"), ("question", "C Answer", "blocked", "web"), ("idle", "D Idle", "idle", "web")]
            let boxes: [JSONValue] = definitions.map { id, title, state, team in
                .object(["id": .string(id), "projectId": .string("demo"), "displayName": .string(title + ": status message"),
                    "config": .object(["name": .string(title)]), "meta": .object(["tags": .object(["team": .string(team)])]),
                    "runtime": .object(["state": .string("ready"), "runtimeState": .string("running"), "agentStatus": .object([
                        "observedAt": .string(Date().ISO8601Format()), "sessions": .array([session(state, kind: state == "blocked" ? "question" : "", title: title, message: "status message")])
                    ])])])
            }
            return try JSONEncoder().encode(JSONValue.object(["sandboxes": .array(boxes)]))
        }
        if request.operation == .approvals {
            let items: [JSONValue] = ["first", "second"].map { .object(["kind": .string("credential"), "credential": .object(["id": .string($0), "sandboxId": .string("approval"), "status": .string("pending"), "name": .string("Repository")])]) }
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(items)]))
        }
        return try await demo.perform(request)
    }
}
