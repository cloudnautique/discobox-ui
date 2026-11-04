import AppKit
import SwiftUI
import Observation
import DiscoboxCore

/// A server acknowledges a write, then deliberately stalls its next read.
/// Exercise real sheets so a late completion cannot close a newer dialog.
@MainActor enum DialogReceiptSmoke {
    static func verify() async throws {
        for approval in [false, true] {
            let client = DialogReceiptClient(), workspace = Workspace()
            await workspace.connect(client: client, label: "Dialog receipt fixture", demo: true)
            await workspace.selectBox("demo-api")
            await workspace.refreshApprovals()
            guard let box = workspace.selectedBox, let item = workspace.approvals.first,
                  let other = workspace.sandboxes.first(where: { $0.id == "demo-ui" }) else { throw DiscoboxError("Dialog receipt fixtures missing") }
            let model = DialogReceiptModel()
            let first: DialogReceiptPresentation = approval ? .approval(UUID(), item) : .action(.init(box: box, action: .archive, connection: workspace.connectionID))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: DialogReceiptHost(model: model).environment(workspace).environment(TerminalStore()).environment(ServiceForwards()))
            window.makeKeyAndOrderFront(nil)
            defer { model.dialog = nil; window.orderOut(nil); workspace.disconnect(); Task { await client.release() } }
            await client.arm()
            model.dialog = first
            try await wait { window.attachedSheet?.defaultButtonCell != nil }
            let sheet = window.attachedSheet!
            guard let root = sheet.contentView,
                  let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.cell === sheet.defaultButtonCell && $0.isEnabled }) else {
                throw DiscoboxError("Dialog receipt submit button missing")
            }
            button.performClick(nil)
            try await wait { await client.waiting }
            try await wait { window.attachedSheet == nil && model.dialog == nil }
            let next = DialogReceiptPresentation.action(.init(box: other, action: .rename, connection: workspace.connectionID))
            model.dialog = next
            try await wait { window.attachedSheet?.contentView != nil }
            let nextSheet = window.attachedSheet
            await client.release()
            try await wait { await client.refreshed }
            try await Task.sleep(for: .milliseconds(150))
            guard model.dialog?.id == next.id, window.attachedSheet === nextSheet, await client.writes == 1 else {
                throw DiscoboxError("Late dialog completion dismissed a newer sheet or repeated the mutation")
            }
        }
        print("DIALOG_RECEIPT_SMOKE_OK: archive and approval close before stalled refresh; late completion leaves newer dialog open; one mutation each")
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(line: Int = #line, _ predicate: () async -> Bool) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Dialog receipt UI check timed out at line \(line)")
    }
}

private enum DialogReceiptPresentation: Identifiable {
    case action(BoxActionRequest)
    case approval(UUID, ApprovalItem)
    var id: UUID {
        switch self { case .action(let request): request.id; case .approval(let id, _): id }
    }
}
@MainActor @Observable private final class DialogReceiptModel {
    var dialog: DialogReceiptPresentation?
}
private struct DialogReceiptHost: View {
    @Bindable var model: DialogReceiptModel
    var body: some View {
        Color.clear.sheet(item: $model.dialog) { dialog in
            switch dialog {
            case .action(let request): BoxActionSheet(request: request).id(dialog.id)
            case .approval(_, let item): ApprovalSheet(item: item).id(dialog.id)
            }
        }
    }
}

private actor DialogReceiptClient: DiscoboxClient {
    private let demo = DemoClient(pendingRequests: true)
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private(set) var refreshed = false
    private(set) var writes = 0
    func arm() { armed = true }
    func release() { armed = false; continuation?.resume(); continuation = nil }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .answer || request.operation == .boxAction {
            let result = try await demo.perform(request)
            writes += 1
            return result
        }
        if armed && writes > 0 && [.sandboxes, .approvals].contains(request.operation) {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            let result = try await demo.perform(request)
            refreshed = true
            return result
        }
        return try await demo.perform(request)
    }
}
