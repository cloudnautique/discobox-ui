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
