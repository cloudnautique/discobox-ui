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
            await model.load(); model.selectBox("demo-ui")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: HarnessManagementView(harness: harness, manager: model, computer: "Fixture computer", openBox: { _ in }, newBox: {}, console: {}, close: {}))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            try await wait { saveButton(window)?.isEnabled == true }
            saveButton(window)!.performClick(nil)
            try await wait { model.review != .null && !model.busy }
            try await wait { saveButton(window) != nil && reviewButton(window) != nil }
            guard saveButton(window)?.isEnabled == false else { throw DiscoboxError("Save enabled before review") }
            try click(reviewButton(window)!, window: window)
            try await wait { saveButton(window)?.isEnabled == true }
            window.setContentSize(NSSize(width: 900, height: 760))
            try await Task.sleep(for: .milliseconds(150))
            guard saveButton(window)?.isEnabled == true else { throw DiscoboxError("Resizing lost review consent") }
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
            print("HARNESS_MANAGEMENT_SMOKE_OK: overview opens focused review, fixed consent/save fit the minimum window and survive resizing, one host-scoped save, durable receipt, and sign-in box keeps its chosen harness")
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
        // SwiftUI exposes AX identity through proxy nodes. In this fixture the
        // checkbox is the first native control in the fixed footer, outside
        // the scrolling diff. The default Save action independently verifies it.
        guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first else { return nil }
        let content = scroll.convert(scroll.bounds, to: root)
        return descendants(root).compactMap { $0 as? NSButton }.filter { button in
            let rect = button.convert(button.bounds, to: root)
            return root.isFlipped ? rect.midY > content.maxY : rect.midY < content.minY
        }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: root).midY
            let right = rhs.convert(rhs.bounds, to: root).midY
            return root.isFlipped ? left < right : left > right
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
