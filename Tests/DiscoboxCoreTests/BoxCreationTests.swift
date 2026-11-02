import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func creatingUnderRunningKeepsStartingBoxVisibleUntilItJoinsTheList() async throws {
    let hub = Connections(polling: false), client = CreationFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    host.workspace.filter = .running
    try await hub.createBox(on: host.id, harness: "demo-harness", repository: "")
    let location = BoxLocation(connection: host.id, box: "created-box")
    #expect(hub.browser.filter == .running && host.workspace.filter == .running)
    #expect(host.workspace.sandboxID == location.box)
    #expect(hub.creationPins.map(\.id) == [location])
    #expect(hub.creationPins.first?.phase == .starting)
    #expect(hub.browser.revealLocation == location)
    let startingReveal = hub.browser.revealRevision
    #expect(!hub.browserBoxes.contains { $0.location == location })
    await client.setPhase(.running)
    await host.workspace.refresh()
    hub.reconcileCreations()
    #expect(hub.browser.filter == .running)
    #expect(host.workspace.sandboxID == location.box)
    #expect(hub.creationPins.isEmpty)
    #expect(hub.browserBoxes.filter { $0.location == location }.count == 1)
    #expect(hub.browser.revealLocation == location)
    #expect(hub.browser.revealRevision != startingReveal)
    #expect(await client.createCount == 1)
}

@MainActor @Test func creationNeverClearsBrowsingContextAndRevealOnlyChangesBlockingFilters() async throws {
    let hub = Connections(polling: false)
    let local = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
    let client = CreationFixture(phase: .running)
    let remote = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .archived
    hub.browser.computerID = local.id
    hub.browser.searchText = "fixture"
    hub.browser.selectedTags = ["repository"]
    hub.browser.matchAnyTag = true
    try await hub.createBox(on: remote.id, harness: "demo-harness", repository: "")
    let location = BoxLocation(connection: remote.id, box: "created-box")
    #expect(hub.activeID == remote.id && remote.workspace.sandboxID == location.box)
    #expect(hub.browser.filter == .archived && hub.browser.computerID == local.id)
    #expect(hub.browser.searchText == "fixture" && hub.browser.selectedTags == ["repository"] && hub.browser.matchAnyTag)
    #expect(hub.browserBoxes.isEmpty)
    #expect(hub.creationPins.map(\.id) == [location])
    #expect(hub.creationPins.first?.phase == .ready)
    await hub.selectBox(location)
    #expect(hub.browser.filter == .archived && hub.browser.archivedSelection.isEmpty)
    await hub.revealCreatedBox(location)
    #expect(hub.browser.filter == .running && hub.browser.computerID == remote.id)
    #expect(hub.browser.searchText == "fixture" && hub.browser.selectedTags == ["repository"] && hub.browser.matchAnyTag)
    #expect(hub.creationPins.isEmpty)
    #expect(hub.browserBoxes.map(\.location) == [location])
    #expect(hub.browser.revealLocation == location)
    #expect(await client.createCount == 1)
}

@MainActor @Test func failedStartupRemainsPinnedAcrossRefreshesWithoutRetryingCreation() async throws {
    let hub = Connections(polling: false), client = CreationFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    try await hub.createBox(on: host.id, harness: "demo-harness", repository: "")
    await client.setPhase(.failed)
    for _ in 0..<3 { await host.workspace.refresh(); hub.reconcileCreations() }
    let pin = try #require(hub.creationPins.first)
    #expect(pin.phase == .failed)
    #expect(pin.message == "Fixture: insufficient disk space")
    #expect(host.workspace.selectedBox?.id == pin.id.box)
    #expect(hub.browser.filter == .running && !hub.browserBoxes.contains { $0.location == pin.id })
    #expect(await client.createCount == 1)
    hub.dismissCreation(pin.id)
    #expect(hub.creationPins.isEmpty)
    #expect(host.workspace.sandboxes.contains { $0.id == pin.id.box })
}

@MainActor @Test func completionDoesNotStealSelectionAndFiltersDoNotResurrectOldReminders() async throws {
    let hub = Connections(polling: false), client = CreationFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    try await hub.createBox(on: host.id, harness: "demo-harness", repository: "")
    await hub.selectBox(.init(connection: host.id, box: "demo-ui"))
    let originalReveal = hub.browser.revealRevision
    await client.setPhase(.running)
    await host.workspace.refresh(); hub.reconcileCreations()
    #expect(hub.creationPins.isEmpty && host.workspace.sandboxID == "demo-ui")
    #expect(hub.browser.revealRevision == originalReveal)
    hub.browser.filter = .archived
    #expect(hub.creationPins.isEmpty)
}

@MainActor @Test func creationRemindersUseHostAndGenerationAndDropRemovedBoxes() async throws {
    let hub = Connections(polling: false), aClient = CreationFixture(), bClient = CreationFixture()
    let a = try await hub.connect(.thisComputer, demo: true) { aClient }
    let b = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { bClient }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    try await hub.createBox(on: a.id, harness: "demo-harness", repository: "")
    try await hub.createBox(on: b.id, harness: "demo-harness", repository: "")
    #expect(Set(hub.creationPins.map(\.id)).count == 2)
    await aClient.removeCreatedBox()
    await a.workspace.refresh(); hub.reconcileCreations()
    #expect(hub.creationPins.map(\.id.connection) == [b.id])
    let oldLocation = try #require(hub.creationPins.first?.id)
    await b.workspace.reconnect()
    hub.reconcileCreations()
    #expect(hub.creationPins.isEmpty)
    await hub.revealCreatedBox(oldLocation)
    #expect(hub.browser.filter == .running)
    #expect(await aClient.createCount == 1)
    #expect(await bClient.createCount == 1)
}

private actor CreationFixture: DiscoboxClient {
    enum Phase { case starting, running, failed }
    let demo = DemoClient()
    var phase: Phase
    var rawID: String?
    var removed = false
    var createCount = 0
    var holdCreatedDetails = false
    var waitingForDetails = false
    var detailsContinuation: CheckedContinuation<Void, Never>?
    init(phase: Phase = .starting) { self.phase = phase }
    func setPhase(_ phase: Phase) { self.phase = phase }
    func removeCreatedBox() { removed = true }
    func holdDetails() { holdCreatedDetails = true }
    func releaseDetails() { holdCreatedDetails = false; detailsContinuation?.resume(); detailsContinuation = nil }
    func runtime() -> [String: Any] {
        switch phase {
        case .starting: ["state": "ready", "runtimeState": "stopped", "displayState": "starting"]
        case .running: ["state": "ready", "runtimeState": "running", "displayState": "running"]
        case .failed: ["state": "failed", "runtimeState": "stopped", "displayState": "failed", "errorMessage": "Fixture: insufficient disk space"]
        }
    }
    func decorate(_ box: [String: Any]) -> [String: Any] {
        var box = box
        box["id"] = "created-box"; box["displayName"] = "Created fixture"; box["runtime"] = runtime()
        return box
    }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .execs, request.sandboxID == "created-box", holdCreatedDetails {
            waitingForDetails = true
            await withCheckedContinuation { detailsContinuation = $0 }
        }
        let data = try await demo.perform(request)
        if request.operation == .createBox {
            createCount += 1
            let box = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            rawID = box["id"] as? String
            return try JSONSerialization.data(withJSONObject: decorate(box))
        }
        if request.operation == .sandboxes, let rawID {
            var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            body["sandboxes"] = (body["sandboxes"] as! [[String: Any]]).compactMap { box in
                guard box["id"] as? String == rawID else { return box }
                return removed ? nil : decorate(box)
            }
            return try JSONSerialization.data(withJSONObject: body)
        }
        return data
    }
}

@MainActor @Test func lateCreationDetailsCannotTrackTheBoxSelectedWhileCreationFinishes() async throws {
    let hub = Connections(polling: false), client = CreationFixture()
    let host = try await hub.connect(.thisComputer, demo: true) { client }
    defer { hub.disconnectAll() }
    hub.browser.filter = .running
    await client.holdDetails()
    let creation = Task { try await hub.createBox(on: host.id, harness: "demo-harness", repository: "") }
    defer { creation.cancel(); Task { await client.releaseDetails() } }
    for _ in 0..<500 {
        if await client.waitingForDetails { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(await client.waitingForDetails)
    await host.workspace.selectBox("demo-ui")
    await client.releaseDetails()
    try await creation.value
    #expect(host.workspace.sandboxID == "demo-ui")
    #expect(hub.creationPins.map(\.id.box) == ["created-box"])
    #expect(await client.createCount == 1)
}
