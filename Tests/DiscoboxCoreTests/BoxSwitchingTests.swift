import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func returningToRecentBoxDoesNotWaitForInventory() async throws {
    let client = SwitchingClient()
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    await workspace.openShell()
    let shell = workspace.execID
    await workspace.selectBox(nil)
    await client.holdNextInventory()
    let returning = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    // The API deliberately cannot respond yet. The retained terminal can mount
    // and take focus anyway, including the previously selected shell.
    #expect(workspace.hasLiveTerminal)
    #expect(workspace.execID == shell)
    #expect(!workspace.inputEnabled)
    await client.release()
    await returning.value
}

@MainActor @Test func expiredInventoryWaitsForFreshState() async {
    var clock = Date()
    let client = SwitchingClient()
    let workspace = Workspace(now: { clock })
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    await workspace.selectBox(nil)
    clock = clock.addingTimeInterval(31)
    await client.holdNextInventory()
    let returning = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    #expect(workspace.execs.isEmpty)
    #expect(!workspace.hasLiveTerminal)
    await client.release()
    await returning.value
    #expect(workspace.hasLiveTerminal)
}

@MainActor @Test func refreshedInventoryReplacesWarmTerminals() async {
    let client = SwitchingClient()
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    await workspace.selectBox(nil)
    await client.holdNextInventory(empty: true)
    let returning = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    #expect(workspace.hasLiveTerminal)
    await client.release()
    await returning.value
    #expect(workspace.execs.isEmpty)
    #expect(workspace.terminalInventory?.box == "demo-ui")
    #expect(workspace.terminalInventory?.execIDs.isEmpty == true)
    #expect(workspace.execID == nil)
    #expect(!workspace.hasLiveTerminal)
}

@MainActor @Test func warmInventoryCannotCrossConnections() async {
    let client = SwitchingClient()
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "first")
    await workspace.selectBox("demo-ui")
    await workspace.selectBox(nil)
    await workspace.connect(client: client, label: "second")
    await client.holdNextInventory()
    let returning = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    #expect(workspace.execs.isEmpty)
    await client.release()
    await returning.value
}

@MainActor @Test func switchingAwayCancelsObsoleteInventoryRequest() async {
    let client = SwitchingClient()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    await client.holdNextInventory()
    let loading = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    await workspace.selectBox(nil)
    await client.release()
    await loading.value
    #expect(await client.cancelled)
    #expect(workspace.sandboxID == nil)
    #expect(workspace.execs.isEmpty)
}

private actor SwitchingClient: DiscoboxClient {
    let demo = DemoClient()
    private var hold = false
    private var empty = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelled = false
    func holdNextInventory(empty: Bool = false) { hold = true; self.empty = empty }
    func waitUntilBlocked() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .execs && hold {
            hold = false
            await withCheckedContinuation { continuation = $0 }
            cancelled = Task.isCancelled
            try Task.checkCancellation()
            if empty { return Data(#"{"execs":[]}"#.utf8) }
        }
        return try await demo.perform(request)
    }
}

@MainActor @Test func terminalCleanupInventorySurvivesLoadingAndClearsOnDisconnect() async {
    let client = SwitchingClient()
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    let inventory = workspace.terminalInventory
    #expect(inventory?.execIDs.isEmpty == false)
    await workspace.selectBox(nil)
    #expect(workspace.execs.isEmpty)
    #expect(workspace.terminalInventory == inventory)
    await client.holdNextInventory()
    let load = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    #expect(workspace.terminalInventory == inventory)
    await client.release()
    await load.value
    workspace.disconnect()
    #expect(workspace.terminalInventory == nil)
}
