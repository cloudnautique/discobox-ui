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
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://", persistentReads: false)
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
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://", persistentReads: false)
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
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://", persistentReads: false)
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
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://", persistentReads: false)
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
        try writeExecutable(script + "\n", to: url)
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
        // Approval reads go to the persistent companion, whose stdin stays
        // open: record the launch before waiting for input.
        let fixture = try FixtureExecutable(script: """
        #!/bin/sh
        printf x >> "$0.calls"
        /bin/cat >/dev/null
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

private struct ProtocolManifest: Decodable {
    struct ReadServer: Decodable { let version: Int; let permissions: [String] }
    let version: Int; let errorKinds: [String]; let operations: [String: String]; let readServer: ReadServer
}
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
    // The persistent companion's framing, and exactly the operations it accepts.
    #expect(manifest.readServer.version == ReadCompanion.protocolVersion)
    #expect(manifest.readServer.permissions == [BridgeRequest.Operation.Permission.read.rawValue])
    for operation in BridgeRequest.Operation.allCases {
        #expect(CompanionClient.usesReadCompanion(operation) == manifest.readServer.permissions.contains(manifest.operations[operation.rawValue] ?? ""), "\(operation)")
    }
}

@Test func everyOperationLaunchesTheCompanionWithOnlyItsPermissionFlag() async throws {
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    while IFS= read -r line; do reply "$(field id)" 200 ''; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let flags: [BridgeRequest.Operation.Permission: String] = [.manage: " --allow-manage", .shell: " --allow-shell"]
    for operation in BridgeRequest.Operation.allCases {
        _ = try await client.perform(.init(operation, projectID: "p"))
        let lines = try String(contentsOf: fixture.url.appendingPathExtension("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        // Reads share one persistent helper that holds no permission flag;
        // every other operation still launches its own, with only its flag.
        #expect(lines.filter { $0.hasPrefix("--read-server") } == ["--read-server --endpoint unix://"], "\(operation)")
        if operation.permission != .read { #expect(lines.last == "--endpoint unix://" + flags[operation.permission]!, "\(operation)") }
    }
}

/// A shell `--read-server` fixture: `field id` / `field sandboxID` read the
/// current `line`; `reply ID STATUS BODY` writes one framed reply. One-shot
/// launches answer an empty success. It never waits for stdin EOF, which on
/// Linux a sibling child can delay by inheriting the pipe.
private let readServerFixture = #"""
#!/bin/sh
printf '%s\n' "$*" >> "$0.args"
if [ "$1" != --read-server ]; then /bin/cat >/dev/null; printf '%s' '{"version":\#(BridgeRequest.protocolVersion),"status":200}'; exit 0; fi
printf x >> "$0.launches"
launch=$(wc -c < "$0.launches" | tr -d ' ')
field() { key="\"$1\":"; v=${line#*"$key"}; v=${v#'"'}; printf '%s' "${v%%[!A-Za-z0-9_-]*}"; }
reply() { printf '{"version":\#(ReadCompanion.protocolVersion),"id":%s,"status":%s,"bodyLength":%s}\n%s' "$1" "$2" "${#3}" "$3"; }

"""#

private func waitForFile(_ url: URL) async throws {
    for _ in 0..<2000 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) never appeared")
}

@Test func persistentReadsShareOneHelperAndMayCompleteOutOfOrder() async throws {
    // Both requests must be in the helper before either is answered, and the
    // second is answered first: each caller still gets its own body.
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    read -r first; read -r second
    for line in "$second" "$first"; do reply "$(field id)" 200 "{\"box\":\"$(field sandboxID)\"}"; done
    while IFS= read -r line; do :; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    async let terminals = client.perform(.init(.execs, projectID: "p", sandboxID: "terminals"))
    async let services = client.perform(.init(.services, projectID: "p", sandboxID: "services"))
    let (execs, ports) = try await (terminals, services)
    #expect(String(decoding: execs, as: UTF8.self) == #"{"box":"terminals"}"#)
    #expect(String(decoding: ports, as: UTF8.self) == #"{"box":"services"}"#)
    #expect(try String(contentsOf: fixture.url.appendingPathExtension("launches"), encoding: .utf8) == "x")
    client.closeConnection()
}

@Test func cancellingOnePersistentReadSendsACancelFrameAndLeavesOthersRunning() async throws {
    // The kept read is answered only after the helper has received the
    // cancel frame for the other one, which must carry that read's id.
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    read -r first; read -r second; : > "$0.both"
    for line in "$first" "$second"; do
        if [ "$(field sandboxID)" = cancelled ]; then cancelled=$(field id); else kept=$(field id); fi
    done
    read -r line
    if [ "$(field id)" = "$cancelled" ] && [ "${line#*'"type":"cancel"'}" != "$line" ]; then echo match > "$0.cancel"; else echo "$line" > "$0.cancel"; fi
    reply "$kept" 200 '{}'
    while IFS= read -r line; do :; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let cancelled = Task { try await client.perform(.init(.execs, projectID: "p", sandboxID: "cancelled")) }
    let kept = Task { try await client.perform(.init(.services, projectID: "p", sandboxID: "kept")) }
    try await waitForFile(fixture.url.appendingPathExtension("both"))
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await kept.value == Data("{}".utf8))
    #expect(try String(contentsOf: fixture.url.appendingPathExtension("cancel"), encoding: .utf8) == "match\n")
    client.closeConnection()
}

@Test func persistentHelperDeathFailsEveryWaiterOnceAndTheNextReadRestartsIt() async throws {
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    if [ "$launch" = 1 ]; then read -r first; read -r second; exit 3; fi
    while IFS= read -r line; do reply "$(field id)" 200 '{}'; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let reads = (0..<2).map { _ in Task { try await client.perform(.init(.sandboxes, projectID: "p")) } }
    for read in reads {
        do {
            _ = try await read.value
            Issue.record("A read survived its helper's death")
        } catch let error as DiscoboxError {
            #expect(error.message == "The companion exited unexpectedly (3).")
            #expect(ConnectionRecovery.canRetry(error))
        }
    }
    #expect(try await client.perform(.init(.sandboxes, projectID: "p")) == Data("{}".utf8))
    #expect(try String(contentsOf: fixture.url.appendingPathExtension("launches"), encoding: .utf8) == "xx")
    client.closeConnection()
}

@Test func aNewGenerationRetiresThePersistentHelperAndClosingStopsReuse() async throws {
    // The first helper holds its read forever; a reconnect cancels it and its
    // replacement answers with its own launch number.
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    if [ "$launch" = 1 ]; then read -r line; : > "$0.held"; while :; do sleep 1; done; fi
    while IFS= read -r line; do reply "$(field id)" 200 "{\"launch\":$launch}"; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    let held = Task { try await client.perform(.init(.sandboxes, projectID: "p")) }
    try await waitForFile(fixture.url.appendingPathExtension("held"))
    client.startGeneration()
    await #expect(throws: CancellationError.self) { try await held.value }
    #expect(try await client.perform(.init(.sandboxes, projectID: "p")) == Data(#"{"launch":2}"#.utf8))
    // A closed connection never starts another persistent helper; a late
    // read takes the one-shot path.
    client.closeConnection()
    _ = try await client.perform(.init(.sandboxes, projectID: "p"))
    #expect(try String(contentsOf: fixture.url.appendingPathExtension("launches"), encoding: .utf8) == "xx")
    let lines = try String(contentsOf: fixture.url.appendingPathExtension("args"), encoding: .utf8).split(separator: "\n")
    #expect(lines.last == "--endpoint unix://")
}

@Test func persistentReplyFramingIsBoundedAndVersioned() throws {
    var frames = ReadCompanion.Frames()
    let reply = Data(#"{"version":1,"id":4,"status":200,"bodyLength":5}"#.utf8 + [10] + Array("{}\n{}".utf8))
    // Split at every byte: a reply completes only with its whole body.
    var replies: [(id: UInt64, reply: ReadCompanion.Reply)] = []
    for byte in reply { replies += try frames.append(Data([byte])) }
    #expect(replies.count == 1 && replies[0].id == 4 && replies[0].reply.body == Data("{}\n{}".utf8))
    for invalid in [Data("not json\n".utf8), Data(#"{"version":2,"id":1,"status":200,"bodyLength":0}"#.utf8 + [10]),
                    Data(#"{"version":1,"id":1,"status":200,"bodyLength":99999999}"#.utf8 + [10]),
                    Data(repeating: 32, count: ReadCompanion.Frames.maxHeader + 1)] {
        var fresh = ReadCompanion.Frames()
        #expect(throws: DiscoboxError.self) { _ = try fresh.append(invalid) }
    }
}

@Test func aVersionMismatchEndsThePersistentHelper() async throws {
    let fixture = try FixtureExecutable(script: readServerFixture + #"""
    while IFS= read -r line; do printf '{"version":99,"id":%s,"status":200,"bodyLength":0}\n' "$(field id)"; done
    """#)
    defer { fixture.remove() }
    let client = CompanionClient(executable: fixture.url, endpoint: "unix://")
    await #expect { try await client.perform(.init(.sandboxes, projectID: "p")) } throws: { error in
        (error as? DiscoboxError)?.message == "Unsupported companion protocol version. Rebuild the app and companion together."
    }
    client.closeConnection()
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
        let framed = try FixtureExecutable(script: readServerFixture + #"""
        while IFS= read -r line; do
            printf '{"version":1,"id":%s,"status":%s,"bodyLength":0,"error":"%s","errorKind":"%s"}\n' "$(field id)" \#(status) '\#(status == 0 ? "fixture failure" : "")' '\#(status == 0 ? wire : "")'
        done
        """#)
        defer { framed.remove() }
        for client in [CompanionClient(executable: fixture.url, endpoint: "unix://", persistentReads: false),
                       CompanionClient(executable: framed.url, endpoint: "unix://")] {
            do {
                _ = try await client.perform(.init(.defaultProject))
                Issue.record("A failed fixture response was accepted")
            } catch let error as DiscoboxError {
                #expect(error.kind == kind, "\(wire) \(status)")
                #expect(error.connectionRetryable == (kind == .transport))
                if status == 401 || status == 403 { #expect(error.message.contains("Access refused")) }
            }
        }
        #expect(try String(contentsOf: framed.url.appendingPathExtension("launches"), encoding: .utf8) == "x")
    }
}
