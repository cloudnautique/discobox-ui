import AppKit
import SwiftUI
import DiscoboxCore

/// Exercises the actual native approval inbox using only in-memory requests.
/// Never connects to Discobox, Keychain or notification services.
@MainActor enum ApprovalQueueSmoke {
    static func run() async {
        do {
            try await verify()
            try await DialogReceiptSmoke.verify()
            print("APPROVAL_QUEUE_SMOKE_OK: Review/Return opens each form, Later preserves requests, three native decisions clear only that box, light/dark layouts fit")
            fflush(stdout); exit(0)
        } catch { print("APPROVAL_QUEUE_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    static func verify() async throws {
        let workspace = Workspace(), client = ApprovalQueueDesktopFixture()
        await workspace.connect(client: client, label: "Offline approval queue", demo: true)
        await workspace.refreshApprovals()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ApprovalInboxView(boxID: "demo-ui").environment(workspace))
        NSApp.activate()
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); workspace.disconnect() }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: scheme)
            try await wait { defaultButton(window)?.isEnabled == true }
            try capture(window, name: scheme == .aqua ? "approval-queue-light" : "approval-queue-dark")
        }
        // Enter's native default action must open the selected request.
        defaultButton(window)?.performClick(nil)
        try await wait { footerButtons(window).count == 4 }
        try capture(window, name: "approval-review-dark")
        footerButtons(window).first?.performClick(nil)
        try await wait { footerButtons(window).count == 3 && defaultButton(window)?.isEnabled == true }
        guard workspace.approvals.filter({ $0.boxID == "demo-ui" }).count == 3, await client.answers.isEmpty else {
            throw DiscoboxError("Later answered a request")
        }
        for remaining in [2, 1, 0] {
            defaultButton(window)?.performClick(nil)
            try await wait { footerButtons(window).count == 4 && footerButtons(window)[2].isEnabled }
            footerButtons(window)[2].performClick(nil)
            try await wait { workspace.approvals.filter { $0.boxID == "demo-ui" }.count == remaining }
            if remaining > 0 { try await wait { footerButtons(window).count == 3 && defaultButton(window)?.isEnabled == true } }
        }
        try await wait { window.defaultButtonCell == nil }
        guard workspace.approvals.map(\.id) == ["other"], await client.answers == ["one", "two", "three"] else {
            throw DiscoboxError("Queue answered the wrong requests or submitted twice")
        }
        try capture(window, name: "approval-queue-empty")
    }
    private static func buttons(_ window: NSWindow) -> [NSButton] {
        guard let root = window.contentView else { return [] }
        return views(root).compactMap { $0 as? NSButton }
    }
    private static func defaultButton(_ window: NSWindow) -> NSButton? {
        buttons(window).first { $0.cell === window.defaultButtonCell }
    }
    // SwiftUI macOS buttons may have empty native titles and AX labels. Match
    // the footer's horizontal row using its default action's actual geometry.
    private static func footerButtons(_ window: NSWindow) -> [NSButton] {
        guard let root = window.contentView, let action = defaultButton(window) else { return [] }
        let y = action.convert(action.bounds, to: root).midY
        return buttons(window).filter { abs($0.convert($0.bounds, to: root).midY - y) < 2 }
            .sorted { $0.convert($0.bounds, to: root).midX < $1.convert($1.bounds, to: root).midX }
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Approval queue UI timed out at line \(line)")
    }
    private static func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private actor ApprovalQueueDesktopFixture: DiscoboxClient {
    private let demo = DemoClient()
    private var pending = ["one", "two", "three", "other"]
    private(set) var answers: [String] = []
    private func item(_ id: String) -> JSONValue {
        .object(["id": .string(id), "sandboxId": .string(id == "other" ? "demo-api" : "demo-ui"),
                 "name": .string("Repository access"), "wellKnownId": .string("test.example.repo"), "envName": .string("GH_TOKEN"), "status": .string("pending"),
                 "justification": .string(id == "two" ? "Let child boxes read the same repository." : "Read repository issues to investigate the reported bug."),
                 id == "two" ? "delegate" : "use": .object(["routes": .array([
                    .object(["hosts": .array([.string("api.example.test")]), "methods": .array([.string("GET")]), "paths": .array([.string("/repos/example/project/**")])])
                 ])])])
    }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .approvals {
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(pending.map { .object(["kind": .string("credential"), "credential": item($0)]) })]))
        }
        if request.operation == .approvalContext {
            return try JSONEncoder().encode(JSONValue.object([
                "request": item(request.requestID ?? "one"), "fingerprint": .string("offline-context"),
                "secrets": .array([.object(["id": .string("fixture-token"), "wellKnownId": .string("test.example.repo"), "name": .string("Repository access"), "maxBindingTTLSeconds": .number(1800)])]),
                "held": .array([]), "bindings": .array([])
            ]))
        }
        if request.operation == .answer {
            let id = request.requestID ?? ""
            guard pending.contains(id), request.action == "deny" else { throw DiscoboxError("Unexpected fixture decision") }
            answers.append(id); pending.removeAll { $0 == id }
            return Data("{}".utf8)
        }
        return try await demo.perform(request)
    }
}
