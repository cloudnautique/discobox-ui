import AppKit
import SwiftUI
import DiscoboxCore

/// Exercise the actual native table and file-promise protocol with temporary
/// local destinations. Never connect to a real server or transfer user files.
@MainActor enum FilesSmoke {
    static func run() async {
        do { try await verify(); fflush(stdout); exit(0) }
        catch { print("FILES_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    static func verify() async throws {
        let client = FilePromiseSmokeClient(), workspace = Workspace()
        await workspace.connect(client: client, label: "Files fixture", demo: true)
        await workspace.selectBox("demo-ui")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: FilesView().environment(workspace))
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil); workspace.disconnect() }
        var table: NSTableView?
        try await wait {
            table = views(view).compactMap { $0 as? NSTableView }.first
            return table?.numberOfRows == 2
        }
        guard let table, let coordinator = table.dataSource as? FilesTable.Coordinator,
              (table.enclosingScrollView?.bounds.height ?? 0) > 150 else { throw DiscoboxError("Files table missing or collapsed") }
        // Multi-selection must survive the SwiftUI/AppKit boundary.
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(50))
        guard table.selectedRowIndexes.count == 2 else { throw DiscoboxError("File multi-selection lost") }
        var providers: [NSFilePromiseProvider] = []
        for row in 0..<2 {
            guard let provider = coordinator.tableView(table, pasteboardWriterForRow: row) as? NSFilePromiseProvider else { throw DiscoboxError("Native file promise missing") }
            providers.append(provider)
        }
        guard await client.downloads.isEmpty else { throw DiscoboxError("Drag started an eager download") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("discobox-file-promises-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        // Switching away must not retarget an accepted Finder drop.
        await workspace.selectBox("demo-tests")
        for provider in providers {
            guard let writer = provider.delegate as? RemoteFilePromiseWriter, provider.userInfo as? RemoteFilePromiseWriter === writer else { throw DiscoboxError("Promise delegate not retained") }
            let name = writer.filePromiseProvider(provider, fileNameForType: provider.fileType)
            let target = destination.appendingPathComponent(name)
            // Invoke the actual native provider delegate. macOS requires a real
            // drag session for its receiver; a synthetic clipboard is not one.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.filePromiseProvider(provider, writePromiseTo: target) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            guard FileManager.default.fileExists(atPath: target.path) else { throw DiscoboxError("Promised file disappeared after completion") }
        }
        let downloads = await client.downloads
        guard downloads.count == 2, downloads.allSatisfy({ $0.sandboxID == "demo-ui" }),
              try String(contentsOf: destination.appendingPathComponent("note.txt"), encoding: .utf8) == "fixture file",
              try String(contentsOf: destination.appendingPathComponent("folder/nested.txt"), encoding: .utf8) == "fixture folder" else {
            throw DiscoboxError("File promise changed destination, computer, box, or content")
        }
        print("FILES_SMOKE_OK: native multi-select, lazy Finder file/folder promises, retained delegates, persistent files, original box after switching")
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(40)) }
        throw DiscoboxError("Files UI fixture timed out")
    }
}

private actor FilePromiseSmokeClient: DiscoboxClient {
    let demo = DemoClient()
    private(set) var downloads: [BridgeRequest] = []
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .files {
            let path = request.remotePath ?? "/workspace/source"
            return try JSONSerialization.data(withJSONObject: ["path": path, "entries": [
                ["path": path + "/note.txt", "name": "note.txt", "type": "file", "size": 12, "version": "1"],
                ["path": path + "/folder", "name": "folder", "type": "directory", "size": 0, "version": "1"]
            ]])
        }
        if request.operation == .download {
            downloads.append(request)
            let local = URL(fileURLWithPath: request.localPath!)
            if request.remotePath!.hasSuffix("/folder") {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                try Data("fixture folder".utf8).write(to: local.appendingPathComponent("nested.txt"), options: .withoutOverwriting)
            } else { try Data("fixture file".utf8).write(to: local, options: .withoutOverwriting) }
            return Data("{}".utf8)
        }
        return try await demo.perform(request)
    }
}
