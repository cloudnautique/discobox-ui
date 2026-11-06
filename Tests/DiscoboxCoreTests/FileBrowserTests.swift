import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func fileUploadsUseTheLoadedFolderInsteadOfAnUnsubmittedPath() async throws {
    let client = FilesFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    #expect(browser.directory == "/workspace/discobox" && browser.canTransfer)
    browser.path = "/not-submitted"
    browser.upload([URL(fileURLWithPath: "/tmp/screenshot with spaces.png")])
    try await waitForFiles { !browser.transferring }
    let writes = await client.writes
    #expect(writes.count == 1)
    #expect(writes[0].remotePath == "/workspace/discobox/screenshot with spaces.png")
    #expect(writes[0].sandboxID == "demo-ui" && writes[0].action == nil)
    #expect(browser.receipt != nil && browser.error == nil)
}

@MainActor @Test func folderDropChecksItsOwnConflictsAndSkipPreservesExistingFiles() async throws {
    let client = FilesFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    browser.upload([URL(fileURLWithPath: "/tmp/existing.txt"), URL(fileURLWithPath: "/tmp/new.txt")], to: "/workspace/source/assets")
    try await waitForFiles { browser.conflict != nil }
    #expect(browser.conflict?.directory == "/workspace/source/assets")
    #expect(await client.writes.isEmpty)
    #expect(!browser.canNavigate)
    browser.resolveConflict(.skip)
    try await waitForFiles { !browser.transferring }
    let writes = await client.writes
    #expect(writes.count == 1 && writes[0].remotePath == "/workspace/source/assets/new.txt")
    #expect(writes[0].action == nil)
}

@MainActor @Test func replacementRequiresConfirmationAndCannotRetargetAfterBoxSwitch() async throws {
    let client = FilesFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    browser.upload([URL(fileURLWithPath: "/tmp/existing.txt")])
    try await waitForFiles { browser.conflict != nil }
    browser.resolveConflict(.replace)
    try await waitForFiles { !browser.transferring }
    #expect(await client.writes.first?.action == "replace")
    browser.upload([URL(fileURLWithPath: "/tmp/existing.txt")])
    try await waitForFiles { browser.conflict != nil }
    await workspace.selectBox("demo-tests")
    browser.resolveConflict(.replace)
    #expect(await client.writes.count == 1)
    #expect(!browser.canTransfer)
}

@MainActor @Test func slowFileListingCannotReplaceANewerFolderOrEnablePrematureDrops() async throws {
    let client = FilesFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    let slow = Task { await browser.load("/slow") }
    try await waitForFiles { await client.waiting }
    #expect(!browser.canTransfer)
    browser.upload([URL(fileURLWithPath: "/tmp/file")])
    await browser.load("/new")
    await client.release()
    await slow.value
    #expect(browser.directory == "/new" && browser.path == "/new")
    #expect(await client.writes.isEmpty)
}

@MainActor @Test func fileTransferFailureClearsBusyAndClosingAPanelPreventsFurtherWrites() async throws {
    let client = FilesFixture(failTransfers: true), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    browser.upload([URL(fileURLWithPath: "/tmp/new.txt")])
    try await waitForFiles { !browser.transferring }
    #expect(browser.error?.contains("disk full") == true && browser.canTransfer)
    browser.close()
    browser.upload([URL(fileURLWithPath: "/tmp/other.txt")])
    #expect(await client.writes.count == 1)
}

@MainActor @Test func filesRejectUnsafeRemoteNamesBeforeTheyCanBecomeLocalPaths() async throws {
    let client = FilesFixture(unsafeNames: true), workspace = Workspace()
    await workspace.connect(client: client, label: "Files", demo: true)
    await workspace.selectBox("demo-ui")
    let browser = try FileBrowser(workspace: workspace)
    await browser.load()
    #expect(browser.error?.contains("unsafe file name") == true)
    #expect(!browser.canTransfer && browser.entries.isEmpty)
}

@MainActor private func waitForFiles(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DiscoboxError("File fixture timed out")
}

private actor FilesFixture: DiscoboxClient {
    let demo = DemoClient()
    let failTransfers: Bool
    let unsafeNames: Bool
    private(set) var writes: [BridgeRequest] = []
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(failTransfers: Bool = false, unsafeNames: Bool = false) { self.failTransfers = failTransfers; self.unsafeNames = unsafeNames }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .files {
            let path = request.remotePath ?? "/workspace/source"
            if path == "/slow" { waiting = true; await withCheckedContinuation { continuation = $0 } }
            let names = unsafeNames ? ["../escape"] : ["existing.txt", "assets"]
            return try JSONSerialization.data(withJSONObject: ["path": path, "entries": names.map { name in
                ["path": path + "/" + name, "name": name, "type": name == "assets" ? "directory" : "file", "size": 10, "version": "1"] as [String: Any]
            }])
        }
        if request.operation == .upload || request.operation == .download {
            writes.append(request)
            if failTransfers { throw DiscoboxError("disk full") }
            return Data("{}".utf8)
        }
        return try await demo.perform(request)
    }
}
