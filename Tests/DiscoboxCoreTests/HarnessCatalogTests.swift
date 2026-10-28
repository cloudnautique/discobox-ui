import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func harnessPrefetchDoesNotBlockConnectionAndSharesOneRequest() async throws {
    let client = CatalogFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    #expect(workspace.isConnected)
    await client.waitUntilBlocked()
    let first = Task { try await workspace.harnesses() }
    let second = Task { try await workspace.harnesses() }
    await client.release()
    #expect(try await first.value.count == 1)
    #expect(try await second.value.count == 1)
    _ = try await workspace.harnesses()
    #expect(await client.calls == 1)
    #expect(workspace.cachedHarnesses.count == 1)
    workspace.disconnect()
    #expect(workspace.cachedHarnesses.isEmpty)
}

private actor CatalogFixture: DiscoboxClient {
    let demo = DemoClient()
    var calls = 0
    private var blocked: CheckedContinuation<Void, Never>?
    func waitUntilBlocked() async { while blocked == nil { await Task.yield() } }
    func release() { blocked?.resume(); blocked = nil }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .harnesses {
            calls += 1
            await withCheckedContinuation { blocked = $0 }
        }
        return try await demo.perform(request)
    }
}

@MainActor @Test func harnessSettingsRefreshBypassesWarmCatalog() async throws {
    let client = RefreshCatalogFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    _ = try await workspace.harnesses()
    #expect(workspace.cachedHarnesses.first?.configured == false)
    await client.configured()
    _ = try await workspace.harnesses()
    #expect(workspace.cachedHarnesses.first?.configured == false)
    _ = try await workspace.harnesses(force: true)
    #expect(workspace.cachedHarnesses.first?.configured == true)
    workspace.disconnect()
}

private actor RefreshCatalogFixture: DiscoboxClient {
    let demo = DemoClient()
    var ready = false
    func configured() { ready = true }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .harnesses {
            return Data("{\"harnessConfigs\":[{\"id\":\"test\",\"name\":\"Test\",\"configured\":\(ready)}]}".utf8)
        }
        return try await demo.perform(request)
    }
}
