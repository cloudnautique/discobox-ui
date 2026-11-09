import AppKit
import SwiftUI
import DiscoboxCore

/// Uses injected fixtures only, including the real native consent controls.
@MainActor enum HarnessManagementSmoke {
    static func run() async {
        do {
            let client = HarnessManagementFixture()
            let workspace = Workspace()
            await workspace.connect(client: client, label: "Harness fixture", demo: true)
            let harness = try JSONDecoder().decode(Harness.self, from: Data(#"{"id":"demo-harness","name":"Subscription agent"}"#.utf8))
            let model = HarnessManagement(workspace: workspace, harnessID: harness.id)
            await model.load(); model.selectBox("demo-ui"); await model.refreshPreview()
            guard model.canSave else { throw DiscoboxError("Missing candidate fixture") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: HarnessManagementView(harness: harness, manager: model, computer: "Fixture computer", openBox: { _ in }, newBox: {}, console: {}, close: {}))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            if let root = window.contentView {
                for view in descendants(root) {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        document.scroll(NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
                fflush(stdout)
            }
            try await wait { saveButton(window) != nil && reviewButton(window) != nil }
            guard saveButton(window)?.isEnabled == false else { throw DiscoboxError("Save enabled before review") }
            try click(reviewButton(window)!, window: window)
            try await wait { saveButton(window)?.isEnabled == true }
            saveButton(window)!.performClick(nil)
            try await wait { model.result["state"].string == "saved-handoff-pending" && !model.busy }
            guard await client.saves == 1 else { throw DiscoboxError("Save duplicated") }
            guard !model.canSave, model.review == .null else { throw DiscoboxError("Completed candidate remained submittable") }
            window.orderOut(nil); model.close()
            let create = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            create.contentView = NSHostingView(rootView: NewBoxSheet(harnessID: "demo-harness").environment(workspace))
            create.orderFront(nil)
            try await wait { descendants(create.contentView!).compactMap { $0 as? NSPopUpButton }.contains { $0.titleOfSelectedItem == "Subscription agent" } }
            create.orderOut(nil); workspace.disconnect()
            print("HARNESS_MANAGEMENT_SMOKE_OK: native review gates save, one host-scoped candidate POST, durable handoff-pending receipt without re-save, and sign-in box keeps its chosen harness")
            fflush(stdout); exit(0)
        } catch { print("HARNESS_MANAGEMENT_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func saveButton(_ window: NSWindow) -> NSButton? {
        guard let root = window.contentView else { return nil }
        return descendants(root).compactMap { $0 as? NSButton }.first { $0.cell === window.defaultButtonCell }
    }
    private static func reviewButton(_ window: NSWindow) -> NSButton? {
        guard let root = window.contentView else { return nil }
        // SwiftUI exposes AX identity through proxy nodes, rather than its
        // backing NSButton. In this fixture the final document control is the
        // review checkbox; the enabled default action independently verifies it.
        guard let document = descendants(root).compactMap({ $0 as? NSScrollView }).first?.documentView else { return nil }
        return descendants(document).compactMap { $0 as? NSButton }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: document).midY
            let right = rhs.convert(rhs.bounds, to: document).midY
            return document.isFlipped ? left > right : left < right
        }.first
    }
    private static func click(_ button: NSButton, window: NSWindow) throws {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard window.contentLayoutRect.contains(point) else { throw DiscoboxError("Review control is outside the visible form: \(point)") }
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw DiscoboxError("Could not create fixture mouse event") }
            NSApp.postEvent(event, atStart: false)
        }
    }
    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<120 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Timed out waiting for native harness controls at line \(line)")
    }
}

private actor HarnessManagementFixture: DiscoboxClient {
    let demo = DemoClient()
    var saves = 0
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .harnesses {
            return Data(#"{"harnessConfigs":[{"id":"first","name":"First agent"},{"id":"demo-harness","name":"Subscription agent"}]}"#.utf8)
        }
        if request.operation == .saveHarnessChanges {
            saves += 1
            guard request.sandboxID == "demo-ui", request.harnessID == "demo-harness", request.payload?["candidateId"].string == "demo-candidate" else { throw DiscoboxError("Save retargeted") }
            return Data(#"{"state":"saved-handoff-pending","harnessConfigId":"demo-harness","candidateId":"demo-candidate"}"#.utf8)
        }
        return try await demo.perform(request)
    }
}
