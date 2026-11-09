import Foundation
import Testing
@testable import DiscoboxCore

@Test func remoteHelperSharesOneProcessAndClosesOnDisconnect() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iroh-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("companion")
    // A second launch fails: concurrent callers must share the first handshake.
    let script = """
    #!/bin/sh
    cd "$(dirname "$0")"
    mkdir launched || exit 1
    read configuration
    printf '%s\\n' '{"endpoint":"unix:///tmp/isolated-iroh-fixture.sock","peerID":"d1-fixture"}'
    exec /bin/cat >/dev/null
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = IrohConnection(executable: executable, endpoint: "discobox://fixture", seed: Data(repeating: 0, count: 32))
    async let first = connection.prepare()
    async let second = connection.prepare()
    let (a,b) = try await (first,second)
    #expect(a == b)
    #expect(a == "unix:///tmp/isolated-iroh-fixture.sock")
    connection.close()
    do { _ = try await connection.prepare(); Issue.record("Closed connection reused") }
    catch { #expect(error.localizedDescription.contains("stopped")) }
}

@MainActor @Test func workspaceSeparatesRemoteAddressAndPrivateTransport() async {
    let client = RemoteFixtureClient()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "discobox://fixture")
    #expect(workspace.isConnected)
    #expect(workspace.endpointLabel == "discobox://fixture")
    #expect(workspace.transportEndpoint == "unix:///tmp/fixture.sock")
    await workspace.reconnect()
    #expect(client.closes == 0)
    #expect(workspace.transportEndpoint == "unix:///tmp/fixture.sock")
    workspace.disconnect()
    #expect(client.closes == 1)
    #expect(workspace.transportEndpoint.isEmpty)
    #expect(workspace.sandboxes.isEmpty)
}

private final class RemoteFixtureClient: DiscoboxClient, @unchecked Sendable {
    private let lock = NSLock()
    private var closeCount = 0
    var closes: Int { lock.withLock { closeCount } }
    func closeConnection() { lock.withLock { closeCount += 1 } }
    func prepareConnection() async throws -> String? { "unix:///tmp/fixture.sock" }
    func perform(_ request: BridgeRequest) async throws -> Data { try await DemoClient().perform(request) }
}

@Test func failedRemoteHelperStartupCanBeRetriedAndStillSharesItsNextHandshake() async throws {
    let fixture = try RestartingIrohFixture(script: """
    read configuration
    if mkdir first 2>/dev/null; then
        printf '%s\\n' '{"error":"temporary transport failure","errorKind":"transport"}'
        exit 1
    fi
    mkdir second || exit 1
    printf '%s\\n' '{"endpoint":"unix:///tmp/recovered-fixture.sock"}'
    exec /bin/cat >/dev/null
    """)
    defer { fixture.remove() }
    let connection = IrohConnection(executable: fixture.url, endpoint: "discobox://fixture", seed: Data(repeating: 0, count: 32))
    defer { connection.close() }
    do { _ = try await connection.prepare(); Issue.record("Failed startup accepted") }
    catch { #expect(ConnectionRecovery.canRetry(error)) }
    async let first = connection.prepare()
    async let second = connection.prepare()
    let (a, b) = try await (first, second)
    #expect(a == "unix:///tmp/recovered-fixture.sock" && a == b)
}

@Test func exitedRemoteHelperRestartsWithoutReplacingTheClientIdentity() async throws {
    let fixture = try RestartingIrohFixture(script: """
    read configuration
    if mkdir first 2>/dev/null; then
        printf '%s\\n' '{"endpoint":"unix:///tmp/first-fixture.sock"}'
        while [ ! -f exit-first ]; do /bin/sleep 0.05; done
        exit 0
    fi
    mkdir second || exit 1
    printf '%s\\n' '{"endpoint":"unix:///tmp/second-fixture.sock"}'
    exec /bin/cat >/dev/null
    """)
    defer { fixture.remove() }
    let connection = IrohConnection(executable: fixture.url, endpoint: "discobox://fixture", seed: Data(repeating: 0, count: 32))
    defer { connection.close() }
    #expect(try await connection.prepare() == "unix:///tmp/first-fixture.sock")
    try Data().write(to: fixture.directory.appendingPathComponent("exit-first"))
    var recovered = ""
    for _ in 0..<50 {
        do { recovered = try await connection.prepare() } catch { }
        if recovered == "unix:///tmp/second-fixture.sock" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(recovered == "unix:///tmp/second-fixture.sock")
    connection.close()
    do { _ = try await connection.prepare(); Issue.record("Explicitly closed helper restarted") } catch { }
}

private struct RestartingIrohFixture {
    let directory: URL
    let url: URL
    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("iroh-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("companion")
        let source = "#!/bin/sh\ncd \"$(dirname \"$0\")\"\n" + script + "\n"
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
