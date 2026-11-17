import Foundation
import Testing
@testable import DiscoboxCore

@Test func companionProtocolUsesPipesAndDecodesBody() async throws {
    let body = Data(#"{"id":"p","name":"Default"}"#.utf8).base64EncodedString()
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s' '{"version":1,"status":200,"body":"\(body)"}'
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
    printf '%s' '{"version":1,"status":401}'
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
    let fixture = try FixtureExecutable(script: """
    #!/bin/sh
    /bin/cat >/dev/null
    mkdir -p "$0.running"; : > "$0.running/$$"
    i=0
    while [ "$(ls "$0.running" | wc -l)" -lt \(count) ]; do
        i=$((i + 1)); [ "$i" -gt 200 ] && { printf '%s' '{"version":1,"status":504}'; exit 0; }
        sleep 0.05
    done
    printf '%s' '{"version":1,"status":200,"body":"e30="}'
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
        let wire = try JSONSerialization.data(withJSONObject: ["version": 1, "status": status, "errorKind": kind, "error": error])
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
