import Foundation
import Testing
@testable import DiscoboxCore

@Test func cadenceFollowsPresenceAndTheActiveComputer() {
    func intervals(_ presence: PollingPresence, active: Bool = true) -> [Duration?] {
        PollingLoop.allCases.map { PollingCadence(presence: presence, isActiveHost: active).interval($0) }
    }
    #expect(intervals(.focused) == [.seconds(3), .seconds(2), .seconds(30), .seconds(60), .seconds(30)])
    #expect(intervals(.focused, active: false) == [.seconds(10), .seconds(5), .seconds(30), .seconds(60), nil])
    #expect(intervals(.visible) == [.seconds(15), .seconds(5), .seconds(30), .seconds(60), .seconds(60)])
    #expect(intervals(.visible, active: false) == [.seconds(15), .seconds(5), .seconds(30), .seconds(60), nil])
    // Approvals keep feeding notifications while hidden; panels pause.
    #expect(intervals(.hidden) == [.seconds(60), .seconds(10), nil, nil, nil])
    #expect(intervals(.hidden, active: false) == intervals(.hidden))
}

@Test func delayCountsFromTheLastPollAndNeverPostponesRecovery() {
    let hidden = PollingCadence(presence: .hidden), focused = PollingCadence()
    #expect(focused.delay(.approvals, sinceLastPoll: nil) == .zero)
    #expect(focused.delay(.approvals, sinceLastPoll: .milliseconds(500)) == .milliseconds(1500))
    #expect(focused.delay(.inventory, sinceLastPoll: .seconds(40))! <= .zero)
    #expect(hidden.delay(.inventory, sinceLastPoll: .seconds(40)) == .seconds(20))
    #expect(hidden.delay(.resources, sinceLastPoll: nil) == nil)
    #expect(hidden.delay(.inventory, sinceLastPoll: .seconds(1), retryIn: 2) == .seconds(2))
    #expect(hidden.delay(.inventory, sinceLastPoll: .seconds(1), retryIn: -5) == .milliseconds(50))
    #expect(focused.delay(.inventory, sinceLastPoll: .seconds(2), retryIn: 30) == .seconds(1))
}

@MainActor @Test func presenceChangesWakeSleepingLoopsOnlyWhenAPollIsDue() async throws {
    let time = ManualPollingTime(), client = CadenceFixture()
    let hub = Connections(now: time.now)
    hub.active.pollSleep = time.sleep
    hub.presence = .hidden
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    #expect(await settle { await client.count(.approvals) == 1 })
    // Advance only after the loop has recorded completion against the fake clock.
    #expect(await settle { time.requested.contains(10) && time.requested.contains(60) })
    let inventory = await client.count(.sandboxes)
    #expect(await client.count(.poolResources) == 0)

    // Hidden: 60s inventory, 10s approvals. Within those, raising presence to
    // visible (15s/5s) only polls what is now due.
    time.advance(8)
    hub.presence = .visible
    #expect(await settle { await client.count(.approvals) == 2 })
    #expect(await settle { time.requested.contains(5) })
    #expect(await settle { await client.count(.poolResources) == 1 })
    #expect(await client.count(.sandboxes) == inventory)

    time.advance(9)
    hub.presence = .hidden
    await settle(rounds: 200) { false }
    #expect(await client.count(.sandboxes) == inventory)
    #expect(await client.count(.approvals) == 2)

    hub.presence = .focused
    #expect(await settle { await client.count(.sandboxes) == inventory + 1 })
    #expect(await settle { await client.count(.approvals) == 3 })
    #expect(host.cadence == PollingCadence(presence: .focused, isActiveHost: true, usageVisible: false))
}

@MainActor @Test func activatingAComputerPromotesOnlyThatComputersCadence() async throws {
    let hub = Connections()
    hub.syncProfiles([.init(name: "Studio", endpoint: "https://studio.example.invalid")])
    let local = hub.sessions[0], studio = hub.sessions[1]
    #expect(local.cadence.isActiveHost && !studio.cadence.isActiveHost)
    hub.activate(studio.id)
    #expect(!local.cadence.isActiveHost && studio.cadence.isActiveHost)
    hub.presence = .hidden
    #expect(hub.sessions.allSatisfy { $0.cadence.presence == .hidden })
}

@MainActor @Test func hiddenInventoryWakesForARetryScheduledElsewhere() async throws {
    let time = ManualPollingTime(), client = CadenceFixture()
    let hub = Connections(now: time.now)
    hub.active.pollSleep = time.sleep
    hub.presence = .hidden
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    #expect(await settle { time.requested.contains(60) })
    await client.setOnline(false)
    await host.refresh()
    #expect(host.connectionState.recovery.nextRetryAt != nil)
    #expect(await settle { time.requested.contains { $0 <= 3 } })
}

@MainActor @discardableResult private func settle(rounds: Int = 10_000, _ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<rounds {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// Time only moves when a test says so; timed sleeps end only when a loop is
/// woken. Drives the session's injectable `now` and `pollSleep`.
private final class ManualPollingTime: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    private var sleeps: [Double] = []
    var requested: [Double] { lock.withLock { sleeps } }
    func advance(_ seconds: Double) { lock.withLock { date += seconds } }
    var now: @Sendable () -> Date { { [self] in lock.withLock { date } } }
    var sleep: @Sendable (PollingLoop, Double) async throws -> Void {
        { [self] _, seconds in
            lock.withLock { sleeps.append(seconds) }
            try await Task.sleep(for: .seconds(86_400))
        }
    }
}

private actor CadenceFixture: DiscoboxClient {
    private let demo = DemoClient(pendingRequests: true)
    private var online = true
    private var requests: [BridgeRequest.Operation] = []
    nonisolated func closeConnection() {}
    func setOnline(_ value: Bool) { online = value }
    func count(_ operation: BridgeRequest.Operation) -> Int { requests.filter { $0 == operation }.count }
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request.operation)
        guard online else { throw URLError(.notConnectedToInternet) }
        return try await demo.perform(request)
    }
}

@MainActor @Test func presenceFollowsTheMostVisibleWorkspaceWindow() {
    let hub = Connections(polling: false)
    let first = UUID(), second = UUID()
    hub.reportPresence(.focused, from: first)
    hub.reportPresence(.hidden, from: second)
    #expect(hub.presence == .focused)
    hub.reportPresence(.visible, from: first)
    #expect(hub.presence == .visible)
    // One window closing never hides another that is still on screen.
    hub.withdrawPresence(from: second)
    #expect(hub.presence == .visible)
    hub.reportPresence(.hidden, from: first)
    #expect(hub.presence == .hidden)
    hub.reportPresence(.focused, from: second)
    hub.withdrawPresence(from: second)
    hub.withdrawPresence(from: first)
    #expect(hub.presence == .hidden)
}

@MainActor @Test func detailReadsStayWithinVisiblePaneBudgets() async {
    var now = Date()
    let session = ConnectionSession(now: { now }), client = CadenceFixture()
    await session.connect(client: client, label: "fixture")
    await session.selection.selectBox("demo-ui")
    for _ in 0..<200 {
        now += 3
        await session.selection.reconcileDetails(cadence: .init())
    }
    #expect(await client.count(.execs) == 21) // initial selection + 20 in ten minutes
    #expect(await client.count(.services) == 0)
    let view = UUID()
    session.selection.showServices(for: "demo-ui", token: view)
    await session.selection.refreshVisibleServices()
    for _ in 0..<200 {
        now += 3
        await session.selection.reconcileDetails(cadence: .init())
    }
    #expect(await client.count(.services) == 11) // panel open followed by 10 reconciliations
    session.selection.hideServices(view)
    now += 600
    await session.selection.reconcileDetails(cadence: .init(presence: .hidden))
    await session.selection.reconcileDetails(cadence: .init(isActiveHost: false))
    #expect(await client.count(.execs) == 41)
    #expect(await client.count(.services) == 11)
    session.disconnect()
}

@MainActor @Test func guestReadFailuresSlowDownEvenWhenTheHostIsConnected() async {
    var now = Date()
    let session = ConnectionSession(now: { now }), client = CadenceFixture()
    await session.connect(client: client, label: "fixture")
    await session.selection.selectBox("demo-ui")
    await client.setOnline(false)
    for _ in 0..<6 {
        now += 30
        await session.selection.reconcileDetails(cadence: .init())
    }
    // Attempts at 30, 60, 120, then due again at 240.
    #expect(await client.count(.execs) == 4)
    #expect(session.selection.detailError != nil)
    #expect(session.selection.hasLiveTerminal)
    #expect(session.connectionState.connectionError == nil)
    session.disconnect()
}

@MainActor @Test func poolBudgetIsSharedAcrossProfilesAndAdmitsOneProbeAfterFailures() {
    let hub = Connections(polling: false), now = Date()
    hub.syncProfiles([.init(name: "Other route", endpoint: "https://studio.example.invalid")])
    let budget = hub.sessions[0].selection.guestBudget, other = hub.sessions[1].selection.guestBudget
    #expect(budget.begin(pool: "p", project: "project", at: now))
    #expect(budget.begin(pool: "p", project: "project", at: now))
    #expect(!other.begin(pool: "p", project: "project", at: now))
    let timeout = Result<Void, Error>.failure(URLError(.timedOut))
    budget.finish(pool: "p", project: "project", at: now, result: timeout)
    budget.finish(pool: "p", project: "project", at: now, result: timeout)
    #expect(!budget.begin(pool: "p", project: "project", at: now))
    #expect(!other.begin(pool: "p", project: "project", at: now))
    let later = now.addingTimeInterval(30)
    #expect(budget.begin(pool: "p", project: "project", at: later))
    #expect(!budget.begin(pool: "p", project: "project", at: later))
    budget.finish(pool: "p", project: "project", at: later, result: .success(()))
    #expect(other.begin(pool: "p", project: "project", at: later))
    #expect(budget.begin(pool: "p", project: "project", at: later))
    #expect(!budget.begin(pool: "p", project: "project", at: later))
    budget.finish(pool: "p", project: "project", at: later, result: .success(()))
}

@MainActor @Test func repeatedPoolTimeoutsReachAndHoldTheFiveMinuteCooldown() {
    let budget = GuestReadBudget()
    var time = Date()
    let timeout = Result<Void, Error>.failure(URLError(.timedOut))
    #expect(budget.begin(pool: "p", project: "project", at: time))
    budget.finish(pool: "p", project: "project", at: time, result: timeout)
    for delay: TimeInterval in [30, 60, 120, 240, 300, 300] {
        #expect(budget.begin(pool: "p", project: "project", at: time))
        budget.finish(pool: "p", project: "project", at: time, result: timeout)
        time += delay
        #expect(!budget.begin(pool: "p", project: "project", at: time.addingTimeInterval(-1)))
    }
    #expect(budget.begin(pool: "p", project: "project", at: time))
}

@MainActor @Test func usageRequiresAnOnscreenExpandedSurfaceOrDetails() {
    let hub = Connections(polling: false), one = UUID(), two = UUID()
    hub.reportPresence(.focused, from: one)
    hub.reportPresence(.hidden, from: two)
    hub.reportUsageSurface(visible: true, from: two)
    #expect(hub.active.cadence.interval(.usage) == nil)
    hub.reportUsageSurface(visible: true, from: one)
    #expect(hub.active.cadence.interval(.usage) == .seconds(60))
    hub.reportUsageSurface(visible: false, from: one)
    #expect(hub.active.cadence.interval(.usage) == nil)
    hub.reportPresence(.visible, from: two)
    #expect(hub.active.cadence.interval(.usage) == .seconds(60))
    hub.withdrawPresence(from: two)
    #expect(hub.active.cadence.interval(.usage) == nil)
}
