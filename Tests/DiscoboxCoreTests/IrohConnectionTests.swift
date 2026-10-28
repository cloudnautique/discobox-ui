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
