import Foundation
import Testing
@testable import DiscoboxCore

private actor PresentedActionClient: DiscoboxClient {
    let demo = DemoClient()
    private(set) var mutations: [String] = []
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .boxAction { mutations.append(request.sandboxID ?? "") }
        return try await demo.perform(request)
    }
}

@MainActor @Test func lifecycleConfirmationSurvivesFilteringAndHostChangesWithoutRetargeting() async throws {
    let connections = Connections(polling: false)
    let localClient = PresentedActionClient(), remoteClient = PresentedActionClient()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(.init(name: "Remote", endpoint: "https://remote.example.invalid"), demo: true) { remoteClient }
    defer { connections.disconnectAll() }
    let localBox = try #require(local.inventory.sandboxes.first { $0.id == "demo-api" })
    let remoteBox = try #require(remote.inventory.sandboxes.first { $0.id == "demo-api" })
    let presentation = BoxActionPresentation()
    presentation.present(.start, box: localBox, on: local, connection: local.connectionState.connectionID)
    let request = try #require(presentation.request)

    connections.browser.filter = .running
    connections.browser.searchText = "row no longer visible"
    connections.activate(remote.id)
    await local.refresh()
    presentation.present(.start, box: remoteBox, on: remote, connection: remote.connectionState.connectionID)
    #expect(presentation.request?.id == request.id)
    #expect(request.host === local)
    #expect(await localClient.mutations.isEmpty)
    #expect(await remoteClient.mutations.isEmpty)

    // Same captured workspace/request used by the window's confirmation sheet.
    try await request.host.commands.performBoxAction(request.action, boxID: request.box.id, connection: request.connection)
    #expect(await localClient.mutations == ["demo-api"])
    #expect(await remoteClient.mutations.isEmpty)
    #expect(connections.activeID == remote.id)
    #expect(connections.browser.filter == .running)
    #expect(connections.browser.searchText == "row no longer visible")
}

@MainActor @Test func lifecycleConfirmationCancelAndReconnectCannotSubmitOldIntent() async throws {
    let connections = Connections(polling: false), first = PresentedActionClient(), second = PresentedActionClient()
    let host = try await connections.connect(.thisComputer, demo: true) { first }
    defer { connections.disconnectAll() }
    let box = try #require(host.inventory.sandboxes.first { $0.id == "demo-api" })
    let generation = host.connectionState.connectionID
    let presentation = BoxActionPresentation()
    presentation.present(.start, box: box, on: host, connection: generation)
    #expect(presentation.request != nil)
    presentation.request = nil // Cancel has no side effects.
    #expect(await first.mutations.isEmpty)
    presentation.present(.start, box: box, on: host, connection: generation)
    let old = try #require(presentation.request)
    await host.connect(client: second, label: "reconnected", demo: true)
    await #expect(throws: DiscoboxError.self) {
        try await old.host.commands.performBoxAction(old.action, boxID: old.box.id, connection: old.connection)
    }
    presentation.request = nil
    presentation.present(.start, box: box, on: host, connection: generation)
    #expect(presentation.request == nil) // An old row callback is also rejected.
    #expect(await second.mutations.isEmpty)
    presentation.present(.start, box: box, on: host, connection: host.connectionState.connectionID)
    #expect(presentation.request?.connection == host.connectionState.connectionID)
}

@MainActor @Test func lifecycleConfirmationRejectsBusyAndChangedRows() async throws {
    let connections = Connections(polling: false), client = PresentedActionClient()
    let host = try await connections.connect(.thisComputer, demo: true) { client }
    defer { connections.disconnectAll() }
    let box = try #require(host.inventory.sandboxes.first { $0.id == "demo-api" })
    let generation = host.connectionState.connectionID
    let presentation = BoxActionPresentation()
    try await host.commands.performBoxAction(.start, boxID: box.id, connection: generation, beforeRequest: {
        presentation.present(.start, box: box, on: host, connection: generation)
        #expect(presentation.request == nil)
    })
    // The stale row still says stopped; fresh inventory now says running.
    presentation.present(.start, box: box, on: host, connection: generation)
    #expect(presentation.request == nil)
    #expect(await client.mutations == ["demo-api"])
}
