import Foundation
import Testing
@testable import DiscoboxCore

@Test func companionProtocolUsesPipesAndDecodesBody() async throws {
    let body = Data(#"{"id":"p","name":"Default"}"#.utf8).base64EncodedString()
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":200,"body":"\(body)"}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let result = try await client.decode(.init(.defaultProject), as: Project.self)
    #expect(result.id == "p")
}

@Test func companionAuthorizationErrorIsActionable() async throws {
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":401}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    do {
        _ = try await client.perform(.init(.defaultProject))
        Issue.record("Unauthorized response was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Access refused"))
    }
}

@Test func cancellingRequestTerminatesOnlyItsFixtureChild() async throws {
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    exec /bin/sleep 30
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let task = Task { try await client.perform(.init(.defaultProject)) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancelled request returned success")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test func inFlightRequestsDoNotOccupyCooperativeThreads() async throws {
    // More helpers than the cooperative pool has threads, each waiting (up to
    // 10s) until all of them are running at once. Requests that held a pool
    // thread each could never all be in flight together, so the barrier would
    // time out; this does not depend on how fast the machine is. Only just
    // over the pool width, so the test itself adds little process pressure.
    let count = ProcessInfo.processInfo.activeProcessorCount + 2
    // The helper never reads stdin: the small request fits in the pipe buffer,
    // and on Linux siblings can inherit each other's stdin, so waiting for EOF
    // there could hold a helper back from the barrier.
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    mkdir -p "$0.running"; : > "$0.running/$$"
    i=0
    while [ "$(ls "$0.running" | wc -l)" -lt \(count) ]; do
        i=$((i + 1)); [ "$i" -gt 200 ] && { printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":504}'; exit 0; }
        sleep 0.05
    done
    printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":200,"body":"e30="}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<count { group.addTask { _ = try await client.perform(.init(.defaultProject)) } }
        try await group.waitForAll()
    }
}

private struct FixtureExecutable {
    let directory: URL
    let url: URL
    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Discobox fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("fixture companion")
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test func companionClassifiesRecoverableErrorsWithoutRetryingTheRequest() async throws {
    for (status, kind, error, retryable) in [(502, "", "", true), (503, "", "", true), (403, "", "", false),
                                            (400, "", "", false), (0, "transport", "fixture connection lost", true),
                                            (0, "", "invalid destination", false)] {
        let wire = try JSONSerialization.data(withJSONObject: ["version": BridgeRequest.protocolVersion, "status": status, "errorKind": kind, "error": error])
        let fixture = try FixtureExecutable(script: """
        #!/bin/sh
        /bin/cat >/dev/null
        printf x >> "$0.calls"
        printf '%s' '\(String(decoding: wire, as: UTF8.self))'
        """)
        defer { fixture.remove() }
        let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
        do {
            _ = try await client.perform(.init(.answer, projectID: "p", requestID: "ask", kind: "credential", action: "deny"))
            Issue.record("Failed fixture response was accepted")
        } catch { #expect(ConnectionRecovery.canRetry(error) == retryable) }
        #expect(try Data(contentsOf: fixture.url.appendingPathExtension("calls")) == Data("x".utf8))
    }
}

@Test func stalledApprovalHelpersTimeOutWithoutReplayingDecisions() async throws {
    for operation in [BridgeRequest.Operation.approvalContext, .approvals, .answer, .createSecret] {
        let fixture = try FixtureExecutable(script: """
        #!/bin/sh
        /bin/cat >/dev/null
        printf x >> "$0.calls"
        trap '' TERM
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let client = CompanionClient(executable: fixture.url, endpoint: "unix://", approvalTimeout: 0.2)
        let started = ContinuousClock.now
        do {
            _ = try await client.perform(.init(operation, projectID: "p", requestID: "ask", kind: "credential", action: "approve"))
            Issue.record("A stalled approval helper returned success")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(ConnectionRecovery.canRetry(error))
            if operation == .answer || operation == .createSecret {
                #expect(error.localizedDescription.contains("may have been recorded"))
                #expect(error.localizedDescription.contains("Nothing was retried"))
            } else { #expect(error.localizedDescription.contains("no decision was sent")) }
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(try Data(contentsOf: fixture.url.appendingPathExtension("calls")) == Data("x".utf8))
    }
}

private struct ProtocolManifest: Decodable { let version: Int; let errorKinds: [String]; let operations: [String: String] }
private func protocolManifest() throws -> ProtocolManifest {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(ProtocolManifest.self, from: Data(contentsOf: root.appendingPathComponent("Companion/protocol.json")))
}

@Test func operationsMatchTheCompanionProtocolManifest() throws {
    let manifest = try protocolManifest()
    #expect(manifest.version == BridgeRequest.protocolVersion)
    let swift = Dictionary(uniqueKeysWithValues: BridgeRequest.Operation.allCases.map { ($0.rawValue, $0.permission.rawValue) })
    #expect(swift == manifest.operations)
    // Every kind the companion reports means something specific to the app.
    #expect(!manifest.errorKinds.isEmpty)
    for kind in manifest.errorKinds { #expect(DiscoboxError.Kind(wire: kind) != .other, "\(kind)") }
}

@Test func everyOperationLaunchesTheCompanionWithOnlyItsPermissionFlag() async throws {
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s\\n' "$*" >> "$0.args"
    printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":200}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let flags: [BridgeRequest.Operation.Permission: String] = [.read: "", .manage: " --allow-manage", .shell: " --allow-shell"]
    for operation in BridgeRequest.Operation.allCases {
        _ = try await client.perform(.init(operation, projectID: "p"))
        let lines = try String(contentsOf: fixture.url.appendingPathExtension("args"), encoding: .utf8).split(separator: "\n")
        #expect(lines.last.map(String.init) == "--endpoint unix://" + flags[operation.permission]!, "\(operation)")
    }
}

@Test @MainActor func renameTravelsAsItsOwnNameField() async throws {
    let session = ConnectionSession()
    await session.connect(client: DemoClient(), label: "fixture", demo: true)
    try await session.commands.performBoxAction(.rename, boxID: "demo-ui", connection: session.connectionState.connectionID, name: "Renamed fixture")
    #expect(session.inventory.sandboxes.first { $0.id == "demo-ui" }?.displayName == "Renamed fixture")
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BridgeRequest(.boxAction, projectID: "p", sandboxID: "s", name: "n", action: "rename"))) as? [String: Any]
    #expect(wire?["name"] as? String == "n" && wire?["prompt"] == nil)
    session.disconnect()
}

@Test func companionErrorsCarryAKindRatherThanMeaningInTheirText() async throws {
    for (wire, status, kind) in [("transport", 0, DiscoboxError.Kind.transport), ("certificate", 0, .certificate), ("unauthorized", 0, .unauthorized),
                                 ("someday-new", 0, .other), ("", 401, .unauthorized), ("", 403, .unauthorized), ("", 400, .other)] {
        let body = try JSONSerialization.data(withJSONObject: status == 0
            ? ["version": BridgeRequest.protocolVersion, "status": 0, "error": "fixture failure", "errorKind": wire]
            : ["version": BridgeRequest.protocolVersion, "status": status])
        let fixture = try FixtureExecutable(script: """
        #!/bin/sh
        /bin/cat >/dev/null
        printf '%s' '\(String(decoding: body, as: UTF8.self))'
        """)
        defer { fixture.remove() }
        do {
            _ = try await CompanionClient(executable: fixture.url, endpoint: "unix://").perform(.init(.defaultProject))
            Issue.record("A failed fixture response was accepted")
        } catch let error as DiscoboxError {
            #expect(error.kind == kind, "\(wire) \(status)")
            #expect(error.connectionRetryable == (kind == .transport))
        }
    }
}

@MainActor @Test func disablingScheduledReadsCancelsOnlyTheirHelpersAndClosesTheDispatchGate() async throws {
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    if [ "$DISCOBOX_UI_READ_TRIGGER" = scheduled ]; then exec /bin/sleep 30; fi
    /bin/cat >/dev/null
    printf '%s' '{"version":\(BridgeRequest.protocolVersion),"status":200,"body":"e30="}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let metrics = ReadMetrics(), generation = UUID()
    func scheduled() async throws -> Data {
        try await GuestReadDiagnostics.$context.withValue(.init(generation: generation, loop: .details, metrics: metrics)) {
            try await GuestReadDiagnostics.$scheduled.withValue(true) { try await client.perform(.init(.execs)) }
        }
    }
    let started = Task { try await scheduled() }
    for _ in 0..<10000 where metrics.inFlight == 0 { await Task.yield() }
    #expect(metrics.inFlight == 1)
    var policy = RefreshPolicy()
    policy.pauseDetails = true
    metrics.apply(policy)
    await #expect(throws: CancellationError.self) { try await started.value }
    await #expect(throws: CancellationError.self) { try await scheduled() }
    #expect(metrics.inFlight == 0 && metrics.started == 1 && metrics.cancelled == 1)
    #expect(try await client.perform(.init(.execs)) == Data("{}".utf8))
}

@MainActor @Test func projectEventProcessDeliversFramesBeforeExitAndPassesTheAppliedCursor() async throws {
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    [ "$1" = --events ] && [ "$3" = unix:///fixture.sock ] && [ "$5" = proj ] && [ "$9" = 42 ] || exit 2
    printf '%s' '{"version":1,"kind":"check'
    printf '%s\n' 'point","id":45}' '{"version":1,"kind":"heartbeat"}'
    """)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix:///fixture.sock")
    var delivered: [ProjectEventFrame] = []
    await #expect(throws: DiscoboxError.self) {
        try await client.readEvents(endpoint: "unix:///fixture.sock", project: "proj", generation: UUID(), after: 42) {
            delivered += $0
        }
    }
    #expect(delivered.map(\.kind) == [.checkpoint, .heartbeat])
    #expect(delivered.first?.id == 45)
}
