import Foundation
import Testing
@testable import DiscoboxCore

@Test func existenceReadyDoesNotMeanRunning() throws {
    let data = Data(#"{"id":"s","projectId":"p","displayName":"Box","config":{},"runtime":{"state":"ready"}}"#.utf8)
    let box = try JSONDecoder().decode(Sandbox.self, from: data)
    #expect(!box.isRunning)
    #expect(box.status == "Power unknown")
}

@Test func unknownStatesAndNullListingsRemainReadable() throws {
    let data = Data(#"{"id":"s","projectId":"p","displayName":"Box","config":{},"runtime":{"state":"future_state","runtimeState":"future_power"}}"#.utf8)
    let box = try JSONDecoder().decode(Sandbox.self, from: data)
    #expect(box.status == "Future State")
    #expect(!box.isRunning)
    let list = try JSONDecoder().decode(SandboxesResponse.self, from: Data(#"{"sandboxes":null}"#.utf8))
    #expect(list.sandboxes == nil)
}

@Test func cachedExecNeverAcceptsInput() throws {
    let data = Data(#"{"id":"e","status":"running","command":["bash"],"workdir":"/workspace","tty":true,"observedAt":"2026-10-26T10:00:00Z"}"#.utf8)
    let exec = try JSONDecoder().decode(Exec.self, from: data)
    #expect(!exec.acceptsInput)
}



@MainActor @Test func viewingAndRefreshingNeverRequestInputOrScreens() async throws {
    let client = RecordingClient()
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    for box in ["demo-ui", "demo-api"] {
        await workspace.selection.selectBox(box)
        await workspace.refresh()
        await workspace.refresh()
    }
    #expect(await client.screenCount == 0)
    #expect(await client.operations.allSatisfy { $0 != "input" })
}

@MainActor @Test func lateConnectionCannotReconnectAfterDisconnect() async {
    let client = GateClient(operation: .defaultProject)
    let workspace = ConnectionSession()
    let pending = Task { await workspace.connect(client: client, label: "fixture") }
    await client.waitUntilBlocked()
    workspace.disconnect()
    await client.release()
    await pending.value
    #expect(!workspace.connectionState.isConnected)
    #expect(workspace.connectionState.projectID == nil)
}

@MainActor @Test func lateSnapshotCannotReplaceNewSelection() async throws {
    let client = GateClient(operation: .screen)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selection.selectBox("demo-api")
    let exec = try #require(workspace.selection.execID)
    let pending = Task { try await workspace.selection.terminalSnapshot(exec: exec) }
    await client.waitUntilBlocked()
    await workspace.selection.selectBox("demo-ui")
    await client.release()
    do { _ = try await pending.value; Issue.record("Accepted output from the prior selection") }
    catch is CancellationError { } catch { Issue.record("Unexpected error: \(error)") }
    #expect(workspace.selection.sandboxID == "demo-ui")
}



@MainActor @Test func resolvesDefaultAliasAndUsesReturnedID() async {
    let client = DefaultProjectClient()
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    #expect(workspace.connectionState.isConnected)
    #expect(workspace.connectionState.projectID == "resolved-default")
    #expect(await client.operations.filter { $0 != "harnesses" } == ["defaultProject", "sandboxes"])
    #expect(await client.listedProject == "resolved-default")
}

@MainActor @Test func missingDefaultDoesNotFallBackToAnotherProject() async {
    let client = DefaultProjectClient(missing: true)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    #expect(!workspace.connectionState.isConnected)
    #expect(workspace.connectionState.projectID == nil)
    #expect(workspace.connectionState.connectionError == "No default project")
    #expect(await client.operations == ["defaultProject"])
}

private actor DefaultProjectClient: DiscoboxClient {
    let missing: Bool
    private(set) var operations: [String] = []
    private(set) var listedProject: String?
    init(missing: Bool = false) { self.missing = missing }
    func perform(_ request: BridgeRequest) async throws -> Data {
        operations.append(request.operation.rawValue)
        switch request.operation {
        case .defaultProject:
            if missing { throw DiscoboxError("No default project") }
            return Data(#"{"id":"resolved-default","name":"My workspace"}"#.utf8)
        case .harnesses:
            return Data(#"{"harnessConfigs":[]}"#.utf8)
        case .sandboxes:
            listedProject = request.projectID
            return Data(#"{"sandboxes":[]}"#.utf8)
        default: throw DiscoboxError("Unexpected operation")
        }
    }
}

private actor RecordingClient: DiscoboxClient {
    private let demo = DemoClient()
    private(set) var screenCount = 0
    private(set) var operations: [String] = []
    func perform(_ request: BridgeRequest) async throws -> Data {
        operations.append(request.operation.rawValue)
        if request.operation == .screen { screenCount += 1 }
        return try await demo.perform(request)
    }
}

private actor GateClient: DiscoboxClient {
    private let demo = DemoClient()
    private let operation: BridgeRequest.Operation
    private var continuation: CheckedContinuation<Void, Never>?
    private var didBlock = false
    init(operation: BridgeRequest.Operation) { self.operation = operation }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == operation && !didBlock {
            didBlock = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await demo.perform(request)
    }
    func waitUntilBlocked() async {
        while continuation == nil { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Test func savedOutputLoadsOnlyOnDemand() async throws {
    let client = RecordingClient()
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selection.selectBox("demo-ui")
    await workspace.refresh()
    #expect(workspace.selection.hasLiveTerminal)
    await workspace.selection.selectBox("demo-api")
    #expect(!workspace.selection.hasLiveTerminal)
    #expect(await client.screenCount == 0)
    let exec = try #require(workspace.selection.execID)
    let screen = try await workspace.selection.terminalSnapshot(exec: exec)
    #expect(screen.exited == true)
    #expect(await client.screenCount == 1)
    await workspace.refresh()
    #expect(await client.screenCount == 1)
    let connection = workspace.connectionState.connectionID
    workspace.disconnect()
    #expect(workspace.connectionState.connectionID != connection)
}

@MainActor @Test func lateShellCreationCannotChangeNewBoxSelection() async {
    let client = GateClient(operation: .newShell)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selection.selectBox("demo-ui")
    let pending = Task { await workspace.selection.openShell() }
    await client.waitUntilBlocked()
    await workspace.selection.selectBox("demo-api")
    let previous = workspace.selection.execID
    await client.release()
    await pending.value
    #expect(workspace.selection.sandboxID == "demo-api")
    #expect(workspace.selection.execID == previous)
    #expect(!workspace.selection.isOpeningShell)
}

@MainActor @Test func demoAuditCreationAndShellCloseStayLocal() async throws {
    let workspace = ConnectionSession()
    await workspace.connect(client: DemoClient(), label: "fixture", demo: true)
    await workspace.selection.selectBox("demo-ui")
    let audit = try await workspace.audit.snapshot(box: "demo-ui")
    #expect(audit.records.count == 2)
    #expect(try await workspace.catalog.harnesses().first?.configured == true)
    try await workspace.selection.closeShell("shell-1")
    #expect(!workspace.selection.execs.contains { $0.id == "shell-1" })
    #expect(workspace.selection.execID == "agent-1")
    try await workspace.commands.createBox(harness: "demo-harness", repository: "")
    #expect(workspace.selection.selectedBox?.displayName == "New demo box")
    let box = workspace.selection.sandboxID
    await workspace.reconnect()
    #expect(workspace.selection.sandboxID == box)
}

@MainActor @Test func connectingScreenLastsUntilInitialInventoryCompletes() async {
    let client = GateClient(operation: .sandboxes)
    let workspace = ConnectionSession()
    let pending = Task { await workspace.connect(client: client, label: "fixture") }
    await client.waitUntilBlocked()
    #expect(workspace.connectionState.isConnecting)
    await client.release()
    await pending.value
    #expect(!workspace.connectionState.isConnecting)
    #expect(workspace.connectionState.isConnected)
}

@MainActor @Test func failedInitialInventoryReturnsToConnectionForm() async {
    let workspace = ConnectionSession()
    await workspace.connect(client: FailingInventoryClient(), label: "fixture")
    #expect(!workspace.connectionState.isConnecting)
    #expect(!workspace.connectionState.isConnected)
    #expect(workspace.connectionState.connectionError == "Fixture server unavailable")
    await workspace.connect(client: DemoClient(), label: "manual retry")
    #expect(workspace.connectionState.isConnected)
    #expect(workspace.connectionState.connectionError == nil)
}

private actor FailingInventoryClient: DiscoboxClient {
    let demo = DemoClient()
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .sandboxes { throw DiscoboxError("Fixture server unavailable") }
        return try await demo.perform(request)
    }
}

@MainActor @Test func slowServicesDoNotDelayLiveTerminalSelection() async throws {
    let client = GateClient(operation: .services)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    workspace.selection.showServices(for: "demo-ui", token: UUID())
    let pending = Task { await workspace.selection.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    // Services remain blocked throughout this check. Allow the independent
    // inventory request to finish and publish the live terminal.
    for _ in 0..<100 {
        if workspace.selection.hasLiveTerminal { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(workspace.selection.hasLiveTerminal)
    #expect(workspace.selection.execID == "agent-1")
    await client.release()
    await pending.value
    #expect(workspace.selection.detailError == nil)
}

@MainActor @Test func lateServicesCannotReplaceNewBoxInventory() async {
    let client = GateClient(operation: .services)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    workspace.selection.showServices(for: "demo-ui", token: UUID())
    let pending = Task { await workspace.selection.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    await workspace.selection.selectBox("demo-api")
    let services = workspace.selection.services
    let observedAt = workspace.selection.servicesObservedAt
    let execs = workspace.selection.execs
    await client.release()
    await pending.value
    #expect(workspace.selection.sandboxID == "demo-api")
    #expect(workspace.selection.services == services)
    #expect(workspace.selection.servicesObservedAt == observedAt)
    #expect(workspace.selection.execs == execs)
}
