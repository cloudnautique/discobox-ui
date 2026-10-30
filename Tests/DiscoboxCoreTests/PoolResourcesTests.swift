import Foundation
import Testing
@testable import DiscoboxCore

private let resourceNow = Date(timeIntervalSince1970: 1_800_000_000)
private func resourcePool(free: Double? = 20_000_000_000, age: TimeInterval = 0, total: Double = 100_000_000_000, schedulable: Bool = true, extra: [String: Any] = [:]) throws -> ResourcePool {
    var report: [String: Any] = [
        "reportedAt": resourceNow.addingTimeInterval(-age).ISO8601Format(),
        "storage": ["filesystem": ["totalBytes": total, "usedBytes": 80_000_000_000, "freeBytes": free as Any? ?? NSNull()], "walk": ["cacheBytes": 900_000_000_000, "observedAt": resourceNow.addingTimeInterval(-3600).ISO8601Format()]],
        "cpu": ["vcpus": 0.5, "capacityVcpus": 8],
        "memory": ["currentBytes": 1024, "capacityBytes": 16_000_000_000, "availableBytes": 8_000_000_000]
    ]
    report.merge(extra) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: ["id": "local", "name": "Development", "schedulable": schedulable, "resources": report])
    return try JSONDecoder().decode(ResourcePool.self, from: data)
}

@Test func resourceHealthUsesAvailableSpaceAndNeverInventsCacheCapacity() throws {
    let healthy = try resourcePool()
    #expect(PoolResourceHealth(pool: healthy, now: resourceNow).level == .healthy)
    #expect(healthy.cacheBytes == 900_000_000_000)
    // A large shared cache cannot establish whether its separate filesystem is full.
    #expect(PoolResourceHealth.cacheLimitation.contains("not reported"))
    #expect(PoolResourceHealth(pool: try resourcePool(free: 0), now: resourceNow).level == .blocked)
    #expect(!PoolResourceHealth(pool: try resourcePool(free: 0), now: resourceNow).canCreate)
    #expect(PoolResourceHealth(pool: try resourcePool(free: 500_000_000), now: resourceNow).level == .warning)
    #expect(PoolResourceHealth(pool: try resourcePool(free: nil), now: resourceNow).level == .unknown)
    #expect(PoolResourceHealth(pool: try resourcePool(free: 0, total: 0), now: resourceNow).level == .unknown)
    #expect(PoolResourceHealth(pool: try resourcePool(free: -1), now: resourceNow).level == .unknown)
    #expect(PoolResourceHealth(pool: try resourcePool(free: 200_000_000_000), now: resourceNow).level == .unknown)
    #expect(PoolResourceHealth(pool: try resourcePool(schedulable: false), now: resourceNow).level == .blocked)
}

@Test func staleMissingAndInvalidatedReportsDoNotClaimCurrentCapacity() throws {
    for age: TimeInterval in [91, 3600, -31] {
        let health = PoolResourceHealth(pool: try resourcePool(free: 0, age: age), now: resourceNow)
        #expect(health.level == .stale && health.canCreate)
    }
    #expect(PoolResourceHealth(pool: try resourcePool(free: 0), now: resourceNow, readFailed: true).level == .stale)
    #expect(PoolResourceHealth(pool: try resourcePool(free: 0), now: resourceNow, invalidatedAt: resourceNow.addingTimeInterval(1)).level == .stale)
    let absent = try JSONDecoder().decode(ResourcePool.self, from: Data(#"{"id":"old","name":"Old agent","resources":{"futureField":true}}"#.utf8))
    #expect(PoolResourceHealth(pool: absent, now: resourceNow).level == .unknown)
    #expect(PoolResourceHealth(pool: nil, now: resourceNow).canCreate)
}

@Test func resourceAccountingMatchesTUIAndDoesNotAttributeSharedCachesToBoxes() throws {
    let box = try JSONDecoder().decode(Sandbox.self, from: Data(#"{"id":"box","projectId":"p","displayName":"Box","poolId":"local","config":{},"runtime":{"state":"ready","runtimeState":"running","resources":{"cpu":{"vcpus":1.25},"memory":{"currentBytes":2048,"residentBytes":9999},"storage":{"totalBytes":4096}}}}"#.utf8))
    let pool = try resourcePool()
    #expect(box.resourceMemory == 2048)
    #expect(box.resourceDisk == 4096)
    #expect(pool.totalCPU(boxes: [box]) == 1.75)
    #expect(pool.totalMemory(boxes: [box]) == 3072)
    let missing = try JSONDecoder().decode(Sandbox.self, from: Data(#"{"id":"unknown","projectId":"p","displayName":"Unknown","poolId":"local","config":{},"runtime":{"state":"ready","runtimeState":"running"}}"#.utf8))
    #expect(pool.totalCPU(boxes: [box, missing]) == nil)
    let stored = try resourcePool(extra: ["total": ["cpuVcpus": 4.0, "memoryBytes": 8192]])
    #expect(stored.totalCPU(boxes: [box, missing]) == 4)
    #expect(stored.totalMemory(boxes: [box, missing]) == 8192)
}

private actor ResourceFixture: DiscoboxClient {
    let demo = DemoClient()
    var snapshot: Data?
    var failRead = false
    var failClear = false
    var reads = 0
    var creates: [BridgeRequest] = []
    var clears: [BridgeRequest] = []
    var hold: BridgeRequest.Operation?
    private var blocked: CheckedContinuation<Void, Never>?
    init(snapshot: Data? = nil) { self.snapshot = snapshot }
    func failures(read: Bool = false, clear: Bool = false) { failRead = read; failClear = clear }
    func holdNext(_ operation: BridgeRequest.Operation) { hold = operation }
    func isBlocked() -> Bool { blocked != nil }
    func release() { blocked?.resume(); blocked = nil }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .poolResources { reads += 1 }
        if request.operation == .createBox { creates.append(request) }
        if request.operation == .clearPoolCache { clears.append(request) }
        if hold == request.operation {
            hold = nil
            await withCheckedContinuation { blocked = $0 }
        }
        if request.operation == .poolResources {
            if failRead { throw DiscoboxError("Resource report unavailable") }
            if let snapshot { return snapshot }
        }
        if request.operation == .clearPoolCache && failClear { throw DiscoboxError("Lost cleanup response") }
        return try await demo.perform(request)
    }
}

private func resourceSnapshot(_ pool: ResourcePool) throws -> Data {
    let encoded = try JSONEncoder().encode(pool)
    return Data(("{\"defaultPoolId\":\"local\",\"pools\":[" + String(decoding: encoded, as: UTF8.self) + "]}").utf8)
}

@MainActor private func waitForResourceBlock(_ client: ResourceFixture) async {
    for _ in 0..<1000 {
        if await client.isBlocked() { return }
        await Task.yield()
    }
    Issue.record("Resource fixture did not block")
}

@MainActor @Test func resourceReadsCoalesceCacheAndBackOffWithoutBlockingBoxSwitching() async throws {
    let client = ResourceFixture(snapshot: try resourceSnapshot(resourcePool()))
    let workspace = Workspace(now: { resourceNow })
    await workspace.connect(client: client, label: "fixture")
    await client.holdNext(.poolResources)
    let first = Task { await workspace.refreshResources() }
    await waitForResourceBlock(client)
    let second = Task { await workspace.refreshResources(force: true) }
    await workspace.selectBox("demo-ui")
    #expect(workspace.sandboxID == "demo-ui" && !workspace.execs.isEmpty)
    await client.release()
    await first.value; await second.value
    #expect(await client.reads == 1)
    #expect(workspace.resources.defaultPoolID == "local")
    await workspace.refreshResources()
    #expect(await client.reads == 1)
    await client.failures(read: true)
    await workspace.refreshResources(force: true)
    await workspace.refreshResources()
    #expect(await client.reads == 2)
    #expect(workspace.resources.error != nil)
    #expect(workspace.resources.health("local", now: resourceNow).level == .stale)
    workspace.disconnect()
}

@MainActor @Test func creationChecksDestinationAndDoesNotBlockOnUnavailableTelemetry() async throws {
    let full = ResourceFixture(snapshot: try resourceSnapshot(resourcePool(free: 0)))
    let workspace = Workspace(now: { resourceNow })
    await workspace.connect(client: full, label: "fixture")
    await #expect(throws: DiscoboxError.self) { try await workspace.createBox(harness: "demo-harness", repository: "", poolID: "local") }
    #expect(await full.creates.isEmpty)
    let available = ResourceFixture(snapshot: try resourceSnapshot(resourcePool()))
    await workspace.connect(client: available, label: "fixture")
    try await workspace.createBox(harness: "demo-harness", repository: "", poolID: "local", connection: workspace.connectionID)
    #expect(await available.creates.last?.poolID == "local")
    #expect(workspace.selectedBox?.poolId == "local")
    await available.failures(read: true)
    try await workspace.createBox(harness: "demo-harness", repository: "", poolID: "local")
    #expect(await available.creates.count == 2)
    workspace.disconnect()
}

@MainActor @Test func creationCannotCrossAReconnectWhilePreflightWaits() async throws {
    let client = ResourceFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "first")
    let original = workspace.connectionID
    await client.holdNext(.poolResources)
    let creating = Task { try await workspace.createBox(harness: "demo-harness", repository: "", poolID: "local", connection: original) }
    await waitForResourceBlock(client)
    await workspace.connect(client: DemoClient(), label: "second", demo: true)
    await client.release()
    do { try await creating.value; Issue.record("Stale preflight created a box") } catch { }
    #expect(await client.creates.isEmpty)
    workspace.disconnect()
}

@MainActor @Test func cleanupIsPoolScopedAndDoesNotRetargetWhenComputersSwitch() async throws {
    let connections = Connections(polling: false)
    let local = try await connections.connect(.thisComputer, demo: true) { ResourceFixture() }
    let remoteClient = ResourceFixture()
    let remote = try await connections.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { remoteClient }
    await remote.workspace.refreshResources()
    await remote.workspace.selectBox("demo-ui")
    let generation = remote.workspace.connectionID
    connections.activate(local.id)
    var detached: [String] = []
    let result = try await remote.workspace.clearPoolCache(poolID: "local", connection: generation) { ids in
        detached = ids
        #expect(remote.workspace.sandboxID == nil)
        #expect(remote.workspace.pendingBoxActions.contains("demo-ui"))
    }
    #expect(result.stoppedSandboxIds == ["demo-ui"])
    #expect(Set(detached) == ["demo-ui", "demo-api"])
    #expect(remote.workspace.sandboxes.first { $0.id == "demo-ui" }?.isRunning == false)
    #expect(local.workspace.sandboxes.first { $0.id == "demo-ui" }?.isRunning == true)
    #expect(connections.active === local)
    #expect(remote.workspace.clearingPools.isEmpty && remote.workspace.pendingBoxActions.isEmpty)
    #expect(await remoteClient.clears.count == 1)
    #expect(await remoteClient.clears.first?.poolID == "local")
    await #expect(throws: DiscoboxError.self) { _ = try await remote.workspace.clearPoolCache(poolID: "remote", connection: UUID()) }
    #expect(await remoteClient.clears.count == 1)
    connections.disconnectAll()
}

@MainActor @Test func cleanupBlocksCompetingCreationAndDoesNotRetryAmbiguousFailure() async throws {
    let client = ResourceFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    await workspace.refreshResources()
    await client.failures(clear: true)
    await client.holdNext(.clearPoolCache)
    let clearing = Task { try await workspace.clearPoolCache(poolID: "local", connection: workspace.connectionID) }
    await waitForResourceBlock(client)
    await #expect(throws: DiscoboxError.self) { try await workspace.createBox(harness: "demo-harness", repository: "", poolID: "local") }
    await #expect(throws: DiscoboxError.self) { try await workspace.performBoxAction(.start, boxID: "demo-api", connection: workspace.connectionID) }
    #expect(await client.creates.isEmpty)
    await client.release()
    do { _ = try await clearing.value; Issue.record("Expected cleanup response failure") } catch { }
    #expect(await client.clears.count == 1)
    #expect(workspace.clearingPools.isEmpty && workspace.pendingBoxActions.isEmpty)
    workspace.disconnect()
}
