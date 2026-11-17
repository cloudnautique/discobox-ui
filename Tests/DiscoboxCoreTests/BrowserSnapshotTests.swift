import Foundation
import Observation
import Testing
@testable import DiscoboxCore

/// main's per-read derivation that the memo replaced, kept as the reference:
/// rows built from each session, then BoxBrowser's selectors.
@MainActor private func referenceQualified(_ hub: Connections) -> [ConnectedBox] {
    hub.sessions.filter { $0.connectionState.isConnected }.flatMap { host in
        host.inventory.sandboxes.filter { !$0.isDeleted }.map { box in
            let activity = host.activity(for: box)
            return ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.profile.displayName,
                box: box, needsAttention: box.matchesAttention || activity.needsYou, activity: activity, power: host.powerStatus(for: box))
        }
    }
}
@MainActor private func referenceCandidates(_ hub: Connections) -> [ConnectedBox] { hub.browser.candidates(in: referenceQualified(hub)) }
@MainActor private func referenceSwitcher(_ hub: Connections) -> [BoxLocation] { hub.browser.switcherBoxes(in: referenceQualified(hub)).map(\.location) }

@MainActor private func snapshotHub() async throws -> (Connections, ConnectionSession, ConnectionSession, SnapshotFixture, SnapshotFixture) {
    let hub = Connections(polling: false), a = SnapshotFixture(), b = SnapshotFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { a }
    let remote = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { b }
    await local.approvalStore.refreshApprovals(); await remote.approvalStore.refreshApprovals()
    return (hub, local, remote, a, b)
}

private final class Flag: @unchecked Sendable { var fired = false }

/// True when a change notifies a reader that only read `browserSnapshot`.
@MainActor private func notifiesSnapshotReader(_ hub: Connections, _ change: () async -> Void) async -> Bool {
    let flag = Flag()
    withObservationTracking { _ = hub.browserSnapshot } onChange: { flag.fired = true }
    await change()
    return flag.fired
}

@MainActor @Test func snapshotMatchesTheReferenceOrderingAndCountsForEveryScope() async throws {
    let (hub, _, remote, _, _) = try await snapshotHub()
    defer { hub.disconnectAll() }
    for computer in [nil, remote.id] {
        for filter in BoxFilter.allCases {
            for search in ["", "api", "Studio", "zzz"] {
                for tags in [Set<String>(), ["team=api"]] {
                    for quick in [nil, BoxActivityFilter.needsYou, .working] {
                        hub.browser.computerID = computer; hub.browser.filter = filter; hub.browser.searchText = search
                        hub.browser.selectedTags = tags; hub.browser.activityFilter = quick
                        let reference = referenceCandidates(hub), snapshot = hub.browserSnapshot
                        #expect(snapshot.candidates == reference)
                        #expect(snapshot.boxes == reference.filter { item in filter == .archived || quick.map { $0.matches(item.activity!, box: item.box) } != false })
                        #expect(snapshot.needsYouCount == reference.filter(\.needsAttention).count)
                        #expect(snapshot.workingCount == reference.filter { $0.activity?.isWorking == true }.count)
                    }
                }
            }
        }
    }
    // Titles sort without the appended activity message; the switcher keeps attention first.
    hub.browser.computerID = nil; hub.browser.filter = .all; hub.browser.searchText = ""; hub.browser.selectedTags = []; hub.browser.activityFilter = nil
    #expect(hub.browserBoxes.map(\.title).prefix(4) == ["A Work", "A Work", "B Approval", "B Approval"])
    #expect(hub.switcherBoxes.map(\.location) == referenceSwitcher(hub))
    #expect(hub.switcherBoxes.prefix(4).allSatisfy { $0.needsAttention })
}

@MainActor @Test func currentBoxStaysOutsideResultsAndCounts() async throws {
    let (hub, local, _, a, _) = try await snapshotHub()
    defer { hub.disconnectAll() }
    let location = BoxLocation(connection: local.id, box: "work")
    await hub.selectBox(location)
    hub.browser.activityFilter = .working
    let counts = (hub.browserSnapshot.needsYouCount, hub.browserSnapshot.workingCount)
    #expect(counts == (6, 2) && hub.browserSelectionPin == nil)
    await a.set("work", state: "idle"); await local.refresh()
    #expect(hub.browserSelectionPin?.location == location)
    #expect(!hub.browserBoxes.contains { $0.location == location })
    #expect(hub.browserSnapshot.workingCount == 1 && hub.browserSnapshot.needsYouCount == 6)
    hub.browser.filter = .archived
    #expect(hub.browserSelectionPin == nil) // archived browsing ignores quick filters
}

@MainActor @Test func snapshotReadersAreNotifiedByEveryInputAndUnchangedRefreshesReuseIt() async throws {
    let (hub, local, remote, a, b) = try await snapshotHub()
    defer { hub.disconnectAll() }
    let revision = hub.browserFleet.revision
    #expect(await !notifiesSnapshotReader(hub) { await local.refresh(); await remote.approvalStore.refreshApprovals() })
    #expect(hub.browserFleet.revision == revision)
    #expect(await notifiesSnapshotReader(hub) { await b.request("idle"); await remote.approvalStore.refreshApprovals() })
    #expect(hub.browserBoxes.first { $0.location == .init(connection: remote.id, box: "idle") }?.activity?.approvalCount == 1)
    #expect(await notifiesSnapshotReader(hub) { await a.set("idle", state: "working"); await local.refresh() })
    #expect(hub.browserSnapshot.workingCount == 3 && hub.browserFleet.revision > revision)
    #expect(await notifiesSnapshotReader(hub) { hub.browser.searchText = "Answer" })
    #expect(hub.browserBoxes.map(\.box.id) == ["question", "question"])
    #expect(await notifiesSnapshotReader(hub) { hub.browser.activityFilter = .working })
    #expect(hub.browserBoxes.isEmpty)
    #expect(await notifiesSnapshotReader(hub) { hub.browser.filter = .archived })
    #expect(await notifiesSnapshotReader(hub) { hub.browser.selectedTags = ["team=web"] })
    #expect(await notifiesSnapshotReader(hub) { hub.browser.computerID = local.id })
    #expect(await notifiesSnapshotReader(hub) { hub.disconnect(remote.id) })
    hub.browser.filter = .all; hub.browser.activityFilter = nil; hub.browser.searchText = ""; hub.browser.selectedTags = []
    let snapshot = hub.browserSnapshot, settled = hub.browserFleet.revision
    #expect(hub.browserBoxes == snapshot.boxes && hub.browserFleet.revision == settled)
    #expect(snapshot.boxes.allSatisfy { $0.location.connection == local.id })
}

@Test func activityClockAdvancesOnlyWhenAnAgeCheckCanChange() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let box = try clockBox(observed: start - 100)
    let clock = ActivityClock().advanced(to: start, inventoryObservedAt: start, boxes: [box])
    #expect(clock == ActivityClock(now: start, inventoryIsCurrent: true))
    // Steady refreshes with nothing crossing two minutes keep the tick...
    #expect(clock.advanced(to: start + 20, inventoryObservedAt: start + 20, boxes: [box]) == clock)
    // ...until a report expires (exactly at its deadline, not a bucket later)...
    #expect(clock.advanced(to: start + 21, inventoryObservedAt: start + 21, boxes: [box]).now == start + 21)
    // ...or the minute heartbeat passes.
    let fresh = try clockBox(observed: start)
    #expect(clock.advanced(to: start + 59, inventoryObservedAt: start + 59, boxes: [fresh]) == clock)
    #expect(clock.advanced(to: start + 60, inventoryObservedAt: start + 60, boxes: [fresh]).now == start + 60)
    // A stale box list flips immediately, as does a clock that moved backwards.
    #expect(clock.advanced(to: start + 5, inventoryObservedAt: nil, boxes: [box]) == ActivityClock(now: start + 5, inventoryIsCurrent: false))
    #expect(clock.advanced(to: start - 1, inventoryObservedAt: start, boxes: [box]).now == start - 1)
    // A newly reported time that is fresh at the refresh but not at the old tick.
    #expect(clock.advanced(to: start + 10, inventoryObservedAt: start + 10, boxes: [try clockBox(observed: start + 125)]).now == start + 10)
}

@MainActor @Test func steadyRefreshesKeepTheClockAndExpiryStillMatchesTheWallClock() async throws {
    let start = Date()
    let clockNow = ClockSource(start)
    let workspace = ConnectionSession(now: { clockNow.date })
    let fixture = SnapshotFixture(observed: start)
    await workspace.connect(client: fixture, label: "fixture")
    defer { workspace.disconnect() }
    let box = try #require(workspace.inventory.sandboxes.first { $0.id == "work" })
    let first = workspace.activityClock
    #expect(workspace.activity(for: box).isWorking)
    for offset in [3.0, 30, 59] {
        clockNow.date = start + offset
        let flag = Flag()
        withObservationTracking { _ = workspace.activityClock } onChange: { flag.fired = true }
        await workspace.refresh()
        #expect(!flag.fired && workspace.activityClock == first)
    }
    for offset in [61.0, 100, 119, 121, 200] {
        clockNow.date = start + offset
        await workspace.refresh()
        let box = try #require(workspace.inventory.sandboxes.first { $0.id == "work" })
        let wall = AgentActivity(box: box, reachable: true, now: clockNow.date)
        #expect(workspace.activity(for: box) == wall)
        #expect(workspace.powerStatus(for: box) == BoxPowerStatus(box: box, now: clockNow.date))
    }
    #expect(!workspace.activity(for: box).isWorking && workspace.activity(for: box).state == .unavailable)
}

private final class ClockSource: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private func clockBox(observed: Date) throws -> Sandbox {
    try JSONDecoder().decode(Sandbox.self, from: JSONEncoder().encode(SnapshotFixture.box("work", "A Work", state: "working", team: "api", observed: observed.ISO8601Format())))
}

/// Static inventory: refreshing returns byte-identical boxes until a test changes them.
private actor SnapshotFixture: DiscoboxClient {
    let demo = DemoClient()
    let observed: String
    private var states = ["work": "working", "approval": "idle", "question": "blocked", "idle": "idle", "failed": "error", "stopped": "idle", "old": "idle"]
    private var requests = ["approval", "approval"]
    init(observed: Date = Date()) { self.observed = observed.ISO8601Format() }
    func set(_ id: String, state: String) { states[id] = state }
    func request(_ id: String) { requests.append(id) }
    static func box(_ id: String, _ title: String, state: String, team: String, observed: String, runtime: String = "running", archived: Bool = false) -> JSONValue {
        let session: JSONValue = .object(["primary": .bool(true), "startedAt": .string("2026-01-01T00:00:00Z"), "execStatus": .string("running"), "title": .string(title),
            "programStatus": .object(["state": .string(state), "kind": .string(state == "blocked" ? "question" : ""), "msg": .string("status message")])])
        return .object(["id": .string(id), "projectId": .string("demo"), "displayName": .string(title + ": status message"),
            "config": .object(["name": .string(title)]), "meta": .object(["tags": .object(["team": .string(team)])]),
            "runtime": .object(["state": .string(archived ? "archived" : "ready"), "runtimeState": .string(runtime), "stateReportedAt": .string(observed),
                "agentStatus": .object(["observedAt": .string(observed), "sessions": .array([session])])])])
    }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .sandboxes {
            let definitions = [("work", "A Work", "api", "running", false), ("approval", "B Approval", "api", "running", false), ("question", "C Answer", "web", "running", false),
                               ("idle", "D Idle", "web", "running", false), ("failed", "E Failed", "web", "running", false), ("stopped", "F Stopped", "api", "stopped", false),
                               ("old", "G Old", "api", "stopped", true)]
            let boxes = definitions.map { Self.box($0.0, $0.1, state: states[$0.0] ?? "idle", team: $0.2, observed: observed, runtime: $0.3, archived: $0.4) }
            return try JSONEncoder().encode(JSONValue.object(["sandboxes": .array(boxes)]))
        }
        if request.operation == .approvals {
            let items: [JSONValue] = requests.enumerated().map { index, box in
                .object(["kind": .string("credential"), "credential": .object(["id": .string("request-\(index)"), "sandboxId": .string(box), "status": .string("pending"), "name": .string("Repository")])])
            }
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(items)]))
        }
        return try await demo.perform(request)
    }
}
