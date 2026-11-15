import Foundation
import Testing
@testable import DiscoboxCore

private actor BoxLinkFixture: DiscoboxClient {
    let demo = DemoClient()
    var parsed: JSONValue = .object(["sandbox": .string("demo-ui"), "local": .bool(true)])
    var peer = ""
    var requests: [BridgeRequest] = []
    var held: BridgeRequest.Operation?
    var continuation: CheckedContinuation<Void, Never>?
    func result(box: String = "demo-ui", local: Bool = true, matches: [String] = [], peer: String = "") {
        parsed = .object(["sandbox": .string(box), "local": .bool(local), "matches": .array(matches.map(JSONValue.string)), "peerID": .string(peer)])
    }
    func identity(_ value: String) { peer = value }
    func holdParse() { held = .boxLink }
    func holdDetails() { held = .execs }
    func release() { continuation?.resume(); continuation = nil }
    func blocked() -> Bool { continuation != nil }
    func count(_ op: BridgeRequest.Operation) -> Int { requests.filter { $0.operation == op }.count }
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request)
        if request.operation == held {
            held = nil
            await withCheckedContinuation { continuation = $0 }
        }
        if request.operation == .boxLink {
            return try JSONEncoder().encode(parsed)
        }
        if request.operation == .serverPeer { return try JSONEncoder().encode(JSONValue.object(["peerId": .string(peer)])) }
        return try await demo.perform(request)
    }
}

@MainActor @Test func relativeBoxLinksUseTheOriginatingComputerAndPreserveFilters() async throws {
    let hub = Connections(polling: false), first = BoxLinkFixture(), second = BoxLinkFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { first }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://remote.test"), demo: true) { second }
    hub.activate(local.id)
    hub.browser.filter = .running; hub.browser.searchText = "current search"; hub.browser.computerID = local.id
    await second.result(box: "demo-api") // The same stopped ID exists on both hosts.
    let target = try await hub.resolveBoxLink("discobox:///demo-api", readerID: remote.id, generation: remote.workspace.connectionID)
    #expect(target.location.connection == remote.id)
    try await hub.openBoxLink(target)
    #expect(hub.active === remote)
    #expect(remote.workspace.sandboxID == "demo-api")
    #expect(remote.workspace.selectedBox?.isRunning == false)
    #expect(local.workspace.sandboxID == nil)
    #expect(hub.browser.filter == .running && hub.browser.computerID == local.id && hub.browser.searchText == "current search")
    #expect(await first.count(.boxAction) == 0)
    #expect(await second.count(.boxAction) == 0)
    hub.disconnectAll()
}

@MainActor @Test func lateBoxLinkDetailsDoNotRevealOrRefocusAfterAnotherSelection() async throws {
    let hub = Connections(polling: false), client = BoxLinkFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    let target = try await hub.resolveBoxLink("discobox:///demo-ui", readerID: host.id, generation: host.workspace.connectionID)
    await client.holdDetails()
    let opening = Task { try await hub.openBoxLink(target) }
    for _ in 0..<200 { if await client.blocked() { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await client.blocked())
    await host.workspace.selectBox("demo-api")
    await client.release()
    do { try await opening.value; Issue.record("Late link details refocused an old box") } catch { }
    #expect(host.workspace.sandboxID == "demo-api")
    #expect(hub.browser.revealLocation == nil)
    hub.disconnectAll()
}

@MainActor @Test func qualifiedBoxLinksUseKnownEndpointOrPeerAndNeverConnectUnknownServers() async throws {
    let hub = Connections(polling: false), first = BoxLinkFixture(), second = BoxLinkFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { first }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://remote.test"), demo: true) { second }
    await first.result(local: false, matches: [remote.id])
    let direct = try await hub.resolveBoxLink("discobox+https://remote.test/demo-ui", readerID: local.id, generation: local.workspace.connectionID)
    #expect(direct.location.connection == remote.id)
    #expect(await second.count(.serverPeer) == 0)
    await first.result(local: false, peer: "peer-fixture")
    await second.identity("peer-fixture")
    let byPeer = try await hub.resolveBoxLink("discobox://peer-fixture/demo-ui", readerID: local.id, generation: local.workspace.connectionID)
    #expect(byPeer.location == direct.location)
    await first.identity("peer-fixture")
    await #expect(throws: DiscoboxError.self) {
        try await hub.resolveBoxLink("discobox://peer-fixture/demo-ui", readerID: local.id, generation: local.workspace.connectionID)
    }
    await first.result(local: false)
    await #expect(throws: DiscoboxError.self) {
        try await hub.resolveBoxLink("discobox://unknown.test/demo-ui", readerID: local.id, generation: local.workspace.connectionID)
    }
    #expect(hub.sessions.count == 2 && hub.active === remote)
    #expect(await first.count(.boxAction) == 0)
    #expect(await second.count(.boxAction) == 0)
    hub.disconnectAll()
}

@MainActor @Test func boxLinkPrefixesMustBeUniqueAndMissingBoxesAreRefreshedOnce() async throws {
    let hub = Connections(polling: false), client = BoxLinkFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    await client.result(box: "demo-")
    await #expect(throws: DiscoboxError.self) { try await hub.resolveBoxLink("discobox:///demo-", readerID: host.id, generation: host.workspace.connectionID) }
    await client.result(box: "demo-u")
    let unique = try await hub.resolveBoxLink("discobox:///demo-u", readerID: host.id, generation: host.workspace.connectionID)
    #expect(unique.location.box == "demo-ui")
    await client.result(box: "purged")
    let reads = await client.count(.sandboxes)
    await #expect(throws: DiscoboxError.self) { try await hub.resolveBoxLink("discobox:///purged", readerID: host.id, generation: host.workspace.connectionID) }
    #expect(await client.count(.sandboxes) == reads + 1)
    #expect(await client.count(.boxAction) == 0)
    hub.disconnectAll()
}

@MainActor @Test func boxLinkLookupAndResolvedTargetsCannotCrossReconnects() async throws {
    let hub = Connections(polling: false), client = BoxLinkFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    let target = try await hub.resolveBoxLink("discobox:///demo-ui", readerID: host.id, generation: host.workspace.connectionID)
    await client.holdParse()
    let generation = host.workspace.connectionID
    let pending = Task { try await hub.resolveBoxLink("discobox:///demo-ui", readerID: host.id, generation: generation) }
    for _ in 0..<200 { if await client.blocked() { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await client.blocked())
    await host.workspace.connect(client: DemoClient(), label: host.id, demo: true)
    await client.release()
    do { _ = try await pending.value; Issue.record("A stale link lookup survived a reconnect") } catch { }
    await #expect(throws: DiscoboxError.self) { try await hub.openBoxLink(target) }
    #expect(host.workspace.sandboxID == nil)
    hub.disconnectAll()
}
