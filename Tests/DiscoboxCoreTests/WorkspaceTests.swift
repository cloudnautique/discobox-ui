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

@Test func inputEncodingMatchesBackendContract() throws {
    let request = BridgeRequest(.input, projectID: "p", sandboxID: "s", execID: "e", input: [.text("hello\nworld"), .key("Enter")])
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let parts = try #require(json["input"] as? [[String: String]])
    #expect(parts == [["text":"hello\nworld"], ["key":"Enter"]])
    #expect(json["operation"] as? String == "input")
}

@MainActor @Test func viewingNeverSendsInputAndInputNeedsOptIn() async throws {
    let client = RecordingClient()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    #expect(workspace.canSendInput)
    #expect(!workspace.inputEnabled)
    workspace.draft = "hello"
    await workspace.sendDraft(enter: true)
    #expect(await client.inputCount == 0)
    workspace.inputEnabled = true
    await workspace.sendDraft(enter: true)
    #expect(await client.inputCount == 1)
    #expect(workspace.draft.isEmpty)
    await workspace.selectBox("demo-api")
    #expect(!workspace.canSendInput)
    #expect(!workspace.inputEnabled)
}

@MainActor @Test func lateConnectionCannotReconnectAfterDisconnect() async {
    let client = GateClient(operation: .defaultProject)
    let workspace = Workspace()
    let pending = Task { await workspace.connect(client: client, label: "fixture") }
    await client.waitUntilBlocked()
    workspace.disconnect()
    await client.release()
    await pending.value
    #expect(!workspace.isConnected)
    #expect(workspace.projectID == nil)
}

@MainActor @Test func lateScreenCannotReplaceNewSelection() async {
    let client = GateClient(operation: .screen)
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    let pending = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    await workspace.selectBox("demo-api")
    #expect(workspace.screen?.exited == true)
    await client.release()
    await pending.value
    #expect(workspace.sandboxID == "demo-api")
    #expect(workspace.screen?.exited == true)
}

@MainActor @Test func ambiguousInputFailureIsNotRetried() async {
    let client = RecordingClient(failInput: true)
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    workspace.inputEnabled = true
    workspace.draft = "do something"
    await workspace.sendDraft(enter: true)
    #expect(await client.inputCount == 1)
    #expect(!workspace.inputEnabled)
    #expect(workspace.draft == "do something")
    #expect(workspace.inputError?.contains("may already have arrived") == true)
}

@MainActor @Test func resolvesDefaultAliasAndUsesReturnedID() async {
    let client = DefaultProjectClient()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    #expect(workspace.isConnected)
    #expect(workspace.projectID == "resolved-default")
    #expect(await client.operations.filter { $0 != "harnesses" } == ["defaultProject", "sandboxes"])
    #expect(await client.listedProject == "resolved-default")
}

@MainActor @Test func missingDefaultDoesNotFallBackToAnotherProject() async {
    let client = DefaultProjectClient(missing: true)
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture")
    #expect(!workspace.isConnected)
    #expect(workspace.projectID == nil)
    #expect(workspace.connectionError == "No default project")
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
    private let failInput: Bool
    private(set) var inputCount = 0
    private(set) var screenCount = 0
    init(failInput: Bool = false) { self.failInput = failInput }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .screen { screenCount += 1 }
        if request.operation == .input {
            inputCount += 1
            if failInput { throw DiscoboxError("connection lost") }
        }
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

@MainActor @Test func liveStreamingSkipsScreensButKeepsSavedScreens() async {
    let client = RecordingClient()
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    await workspace.refresh()
    #expect(workspace.hasLiveTerminal)
    #expect(workspace.screen == nil)
    #expect(await client.screenCount == 0)
    await workspace.selectBox("demo-api")
    #expect(!workspace.hasLiveTerminal)
    #expect(workspace.screen != nil)
    #expect(await client.screenCount > 0)
    let connection = workspace.connectionID
    workspace.disconnect()
    #expect(workspace.connectionID != connection)
}

@MainActor @Test func lateShellCreationCannotChangeNewBoxSelection() async {
    let client = GateClient(operation: .newShell)
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    let pending = Task { await workspace.openShell() }
    await client.waitUntilBlocked()
    await workspace.selectBox("demo-api")
    let previous = workspace.execID
    await client.release()
    await pending.value
    #expect(workspace.sandboxID == "demo-api")
    #expect(workspace.execID == previous)
    #expect(!workspace.isOpeningShell)
}

@MainActor @Test func demoAuditCreationAndShellCloseStayLocal() async throws {
    let workspace = Workspace()
    await workspace.connect(client: DemoClient(), label: "fixture", demo: true)
    await workspace.selectBox("demo-ui")
    let audit = try await workspace.auditSnapshot(box: "demo-ui")
    #expect(audit.records.count == 2)
    #expect(try await workspace.harnesses().first?.configured == true)
    try await workspace.closeShell("shell-1")
    #expect(!workspace.execs.contains { $0.id == "shell-1" })
    #expect(workspace.execID == "agent-1")
    try await workspace.createBox(harness: "demo-harness", repository: "")
    #expect(workspace.selectedBox?.displayName == "New demo box")
    let box = workspace.sandboxID
    await workspace.reconnect()
    #expect(workspace.sandboxID == box)
}

@MainActor @Test func connectingScreenLastsUntilInitialInventoryCompletes() async {
    let client = GateClient(operation: .sandboxes)
    let workspace = Workspace()
    let pending = Task { await workspace.connect(client: client, label: "fixture") }
    await client.waitUntilBlocked()
    #expect(workspace.isConnecting)
    await client.release()
    await pending.value
    #expect(!workspace.isConnecting)
    #expect(workspace.isConnected)
}

@MainActor @Test func failedInitialInventoryReturnsToConnectionForm() async {
    let workspace = Workspace()
    await workspace.connect(client: FailingInventoryClient(), label: "fixture")
    #expect(!workspace.isConnecting)
    #expect(!workspace.isConnected)
    #expect(workspace.connectionError == "Fixture server unavailable")
    await workspace.connect(client: DemoClient(), label: "manual retry")
    #expect(workspace.isConnected)
    #expect(workspace.connectionError == nil)
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
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    let pending = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    // Services remain blocked throughout this check. Allow the independent
    // inventory request to finish and publish the live terminal.
    for _ in 0..<100 {
        if workspace.hasLiveTerminal { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(workspace.hasLiveTerminal)
    #expect(workspace.execID == "agent-1")
    await client.release()
    await pending.value
    #expect(workspace.detailError == nil)
}

@MainActor @Test func lateServicesCannotReplaceNewBoxInventory() async {
    let client = GateClient(operation: .services)
    let workspace = Workspace()
    workspace.streamsLiveTerminals = true
    await workspace.connect(client: client, label: "fixture")
    let pending = Task { await workspace.selectBox("demo-ui") }
    await client.waitUntilBlocked()
    await workspace.selectBox("demo-api")
    let services = workspace.services
    let observedAt = workspace.servicesObservedAt
    let execs = workspace.execs
    await client.release()
    await pending.value
    #expect(workspace.sandboxID == "demo-api")
    #expect(workspace.services == services)
    #expect(workspace.servicesObservedAt == observedAt)
    #expect(workspace.execs == execs)
}
