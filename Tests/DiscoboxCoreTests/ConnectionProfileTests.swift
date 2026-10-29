import Foundation
import Testing
@testable import DiscoboxCore

@Test func localComputerNamesAreConsistentAndKeepTheSameConnectionIdentity() {
    let local = ConnectionProfile.localComputer(name: "  Studio Mac  ")
    #expect(local.name == "Studio Mac")
    #expect(local.displayName == "Studio Mac (This computer)")
    #expect(local.id == ConnectionProfile.thisComputer.id)
    #expect(ComputerIdentity.resolvedName(" \n", fallback: "System computer") == "System computer")
    #expect(ConnectionProfile(name: "Studio", endpoint: "discobox://d1-fixture").displayName == "Studio")
}

@Test func peerEnrollmentUsesTheComputerNameWithSafeShellQuoting() throws {
    let name = "Studio's Mac $(printf WRONG)"
    let command = ComputerIdentity.enrollmentCommand(peerID: "d1-fixture", name: name)
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "discobox() { printf '%s\\n' \"$@\"; }\n" + command]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: data, as: UTF8.self) == "admin\npeer\nadd\nd1-fixture\n--name\n" + name + "\n")
}

@Test func savedConnectionsCollapseOnlyTheDefaultLocalSocket() throws {
    let socket = "/tmp/connection-profile-fixture/discobox/server.sock"
    let text = #"[{"name":"This Mac","endpoint":"unix://","relayURLs":""},{"name":"unix:///tmp/connection-profile-fixture/discobox/server.sock","endpoint":"unix:///tmp/connection-profile-fixture/discobox/server.sock","relayURLs":""},{"name":"Custom","endpoint":"unix:///tmp/custom/server.sock","relayURLs":""},{"name":"Studio","endpoint":"discobox://d1-fixture","relayURLs":"https://relay.example.com","directOnly":true}]"#
    let profiles = try #require(ConnectionProfiles.decode(text, defaultSocket: socket))
    #expect(profiles.map(\.name) == ["Custom", "Studio"])
    #expect(profiles.last?.directOnly == true)
    #expect(profiles.last?.relayURLs == "https://relay.example.com")
    let encoded = try #require(ConnectionProfiles.encode(profiles))
    #expect(ConnectionProfiles.decode(encoded, defaultSocket: socket) == profiles)
    #expect(ConnectionProfiles.decode("invalid json") == nil)
}

@Test func legacyAddressNamesBecomeReadableAndDuplicatesCollapse() throws {
    let text = #"[{"name":"discobox://d1-fixture","endpoint":"discobox://d1-fixture","relayURLs":""},{"name":"Latest name","endpoint":"discobox://d1-fixture","relayURLs":"https://relay.example.com"},{"name":"unix:///tmp/custom/server.sock","endpoint":"unix:///tmp/custom/server.sock","relayURLs":""}]"#
    let profiles = try #require(ConnectionProfiles.decode(text))
    #expect(profiles.count == 2)
    #expect(profiles.first?.displayName == "Latest name")
    #expect(profiles.last?.displayName == "Local socket")
    #expect(ConnectionProfile(name: "iroh://d1-fixture", endpoint: "iroh://d1-fixture").displayName == "Remote computer")
}

@Test func connectionEditorValidatesAndTrimsAddresses() throws {
    let profile = try ConnectionProfiles.validated(name: " Studio ", endpoint: " discobox://d1-fixture ", relayURLs: "", directOnly: false)
    #expect(profile.name == "Studio")
    #expect(profile.endpoint == "discobox://d1-fixture")
    #expect(profile.isRemote)
    for endpoint in ["", "relative/socket", "ftp://host", "https://", "unix://relative/socket"] {
        #expect(throws: DiscoboxError.self) { try ConnectionProfiles.validated(name: "Name", endpoint: endpoint, relayURLs: "", directOnly: false) }
    }
    #expect(throws: DiscoboxError.self) { try ConnectionProfiles.validated(name: "  ", endpoint: "unix://", relayURLs: "", directOnly: false) }
}

private final class ProbeFixture: DiscoboxClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BridgeRequest.Operation] = []
    private var closes = 0
    let fails: Bool
    let slow: Bool
    init(fails: Bool = false, slow: Bool = false) { self.fails = fails; self.slow = slow }
    var operations: [BridgeRequest.Operation] { lock.withLock { requests } }
    var closeCount: Int { lock.withLock { closes } }
    func closeConnection() { lock.withLock { closes += 1 } }
    func perform(_ request: BridgeRequest) async throws -> Data {
        lock.withLock { requests.append(request.operation) }
        if slow { try await Task.sleep(for: .seconds(60)) }
        if fails { throw DiscoboxError("Access refused (403)") }
        return Data(#"{"id":"default","name":"Default"}"#.utf8)
    }
}

@Test func connectionProbeOnlyReadsAndClosesItsOwnClient() async throws {
    let active = ProbeFixture()
    let probe = ProbeFixture()
    try await ConnectionProfiles.test(client: probe)
    #expect(probe.operations == [.defaultProject])
    #expect(probe.closeCount == 1)
    #expect(active.closeCount == 0)
    let denied = ProbeFixture(fails: true)
    do { try await ConnectionProfiles.test(client: denied); Issue.record("Denied probe succeeded") }
    catch { #expect(error.localizedDescription.contains("403")) }
    #expect(denied.closeCount == 1)
}

@Test func cancellingConnectionProbeClosesItsClient() async {
    let probe = ProbeFixture(slow: true)
    let task = Task { try await ConnectionProfiles.test(client: probe) }
    while probe.operations.isEmpty { await Task.yield() }
    task.cancel()
    do { try await task.value; Issue.record("Cancelled probe succeeded") } catch { }
    #expect(probe.closeCount >= 1)
}
