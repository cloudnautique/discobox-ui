import Foundation
import Testing
@testable import DiscoboxCore

@Test func cadenceFollowsPresenceAndTheActiveComputer() {
    func intervals(_ presence: PollingPresence, active: Bool = true) -> [Duration?] {
        PollingLoop.allCases.map { PollingCadence(presence: presence, isActiveHost: active).interval($0) }
    }
    #expect(intervals(.focused) == [.seconds(3), .seconds(2), .seconds(30), .seconds(60)])
    #expect(intervals(.focused, active: false) == [.seconds(10), .seconds(5), .seconds(30), .seconds(60)])
    #expect(intervals(.visible) == [.seconds(15), .seconds(5), .seconds(30), .seconds(60)])
    #expect(intervals(.visible, active: false) == intervals(.visible))
    // Approvals keep feeding notifications while hidden; panels pause.
    #expect(intervals(.hidden) == [.seconds(60), .seconds(10), nil, nil])
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
    let time = ManualPollingClock(), client = CadenceFixture()
    let hub = Connections(clock: time.clock)
    hub.presence = .hidden
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    #expect(await settle { await client.count(.approvals) == 1 })
    let inventory = await client.count(.sandboxes)
    #expect(await client.count(.poolResources) == 0)

    // Hidden: 60s inventory, 10s approvals. Within those, raising presence to
    // visible (15s/5s) only polls what is now due.
    time.advance(.seconds(8))
    hub.presence = .visible
    #expect(await settle { await client.count(.approvals) == 2 })
    #expect(await settle { await client.count(.poolResources) == 1 })
    #expect(await client.count(.sandboxes) == inventory)

    time.advance(.seconds(9))
    hub.presence = .hidden
    await settle(rounds: 200) { false }
    #expect(await client.count(.sandboxes) == inventory)
    #expect(await client.count(.approvals) == 2)

    hub.presence = .focused
    #expect(await settle { await client.count(.sandboxes) == inventory + 1 })
    #expect(await settle { await client.count(.approvals) == 3 })
    #expect(host.cadence == PollingCadence(presence: .focused, isActiveHost: true))
}

@MainActor @Test func activatingAComputerPromotesOnlyThatComputersCadence() async throws {
    let hub = Connections(clock: ManualPollingClock().clock)
    hub.syncProfiles([.init(name: "Studio", endpoint: "https://studio.example.invalid")])
    let local = hub.sessions[0], studio = hub.sessions[1]
    #expect(local.cadence.isActiveHost && !studio.cadence.isActiveHost)
    hub.activate(studio.id)
    #expect(!local.cadence.isActiveHost && studio.cadence.isActiveHost)
    hub.presence = .hidden
    #expect(hub.sessions.allSatisfy { $0.cadence.presence == .hidden })
}

@MainActor @Test func hiddenInventoryWakesForARetryScheduledElsewhere() async throws {
    let time = ManualPollingClock(), client = CadenceFixture()
    let hub = Connections(clock: time.clock)
    hub.presence = .hidden
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    #expect(await settle { time.requested.contains(.seconds(60)) })
    await client.setOnline(false)
    await host.workspace.refresh()
    #expect(host.workspace.recovery.nextRetryAt != nil)
    #expect(await settle { time.requested.contains { $0 <= .seconds(3) } })
}

@MainActor @discardableResult private func settle(rounds: Int = 10_000, _ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<rounds {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// Time only moves when a test says so; sleeps end only when a loop is woken.
private final class ManualPollingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero
    private var sleeps: [Duration] = []
    var requested: [Duration] { lock.withLock { sleeps } }
    func advance(_ duration: Duration) { lock.withLock { offset += duration } }
    var clock: PollingClock {
        PollingClock(now: { [self] in origin + lock.withLock { offset } }, sleep: { [self] duration in
            lock.withLock { sleeps.append(duration) }
            try await Task.sleep(for: .seconds(86_400))
        })
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
