#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Uses injected fixtures only, including the real native consent controls.
@MainActor enum HarnessManagementSmoke {
    static func run() async {
        do {
            let client = HarnessManagementFixture()
            let workspace = ConnectionSession()
            await workspace.connect(client: client, label: "Harness fixture", demo: true)
            try await checkDeferredPrompt(workspace: workspace, client: client)
            let harness = try JSONDecoder().decode(Harness.self, from: Data(#"{"id":"demo-harness","name":"Subscription agent"}"#.utf8))
            let model = HarnessManagement(connection: workspace.connectionState, inventory: workspace.inventory, service: workspace.harnessService, sourceBoxID: workspace.selection.sandboxID, harnessID: harness.id)
            await model.load(); model.selectBox("demo-ui")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: HarnessManagementView(harness: harness, manager: model, catalog: workspace.catalog, computer: "Fixture computer", openBox: { _ in }, newBox: {}, console: {}, close: {}))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            try await wait { saveButton(window)?.isEnabled == true }
            saveButton(window)!.performClick(nil)
            try await wait { model.review != .null && !model.busy }
            try await wait { saveButton(window)?.isEnabled == false && reviewButton(window) != nil }
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
            create.orderOut(nil)
            let defaults = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            defaults.contentView = NSHostingView(rootView: NewBoxSheet().environment(workspace))
            defaults.orderFront(nil)
            try await wait { descendants(defaults.contentView!).compactMap { $0 as? NSPopUpButton }.contains { $0.titleOfSelectedItem == "First agent · Default" } }
            defaults.orderOut(nil); workspace.disconnect()
            print("HARNESS_MANAGEMENT_SMOKE_OK: Later survives remount and a newer candidate, header review, explicit save, durable receipt, and launch harness selection")
            fflush(stdout); exit(0)
        } catch { print("HARNESS_MANAGEMENT_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func checkDeferredPrompt(workspace: ConnectionSession, client: HarnessManagementFixture) async throws {
        await workspace.selection.selectBox("demo-ui")
        guard let box = workspace.selection.selectedBox, let harness = Harness(reportedBy: box) else {
            throw DiscoboxError("Missing source harness")
        }
        let suite = "ai.discobox.smoke.harness-prompt." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let blocker = NSAlert()
        blocker.messageText = "Fixture sheet"
        blocker.beginSheetModal(for: window) { _ in }
        var reviewed = false
        func mount(_ selected: Sandbox) {
            let hosting = NSHostingView(rootView: HarnessChangesControl(box: selected, harness: harness, window: window) {
                reviewed = true
            }.frame(width: 640, height: 260).environment(workspace).defaultAppStorage(defaults))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setContentSize(NSSize(width: 640, height: 260))
        }
        mount(box)
        for _ in 0..<120 {
            if await client.previews > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard await client.previews == 1, defaults.string(forKey: "harnessSetupSheets.v1") == nil,
              window.attachedSheet === blocker.window else { throw DiscoboxError("Blocked prompt consumed or missed the candidate") }
        window.endSheet(blocker.window)
        func reviewButton() -> NSButton? {
            window.attachedSheet?.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.title == "Review changes…" } }
        }
        try await wait { reviewButton() != nil }
        guard let sheet = window.attachedSheet?.contentView,
              let later = descendants(sheet).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Later" }) else {
            throw DiscoboxError("Missing Later action")
        }
        later.performClick(nil)
        try await wait { window.attachedSheet == nil }
        // Leaving the box destroys the control. While away, another edit
        // replaces the candidate, and returning constructs a fresh control.
        window.contentView = NSView(frame: window.contentLayoutRect)
        await client.setCandidate("updated-candidate")
        await workspace.refresh()
        guard let updated = workspace.selection.selectedBox else { throw DiscoboxError("Missing updated box") }
        mount(updated)
        // The borderless SwiftUI button is drawn inside the hosting view;
        // unlike the NSAlert buttons it has no descendant NSButton.
        try await wait { !window.contentLayoutRect.isEmpty }
        for _ in 0..<120 {
            if await client.previews >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await Task.yield()
        guard updated.runtime.agentStatus?["harnessConfigCandidate"].string == "updated-candidate",
              !reviewed, window.attachedSheet == nil else { throw DiscoboxError("Later reopened the sheet on return") }
        let content = window.contentLayoutRect
        try click(at: NSPoint(x: content.midX, y: content.midY), window: window)
        try await wait { reviewed }
        await client.setCandidate("demo-candidate")
        await workspace.refresh()
        guard await client.saves == 0 else { throw DiscoboxError("Opening the review saved the candidate") }
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
        try click(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), window: window)
    }
    private static func click(at point: NSPoint, window: NSWindow) throws {
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
    var previews = 0
    private var candidate = "demo-candidate"
    func setCandidate(_ id: String) { candidate = id }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .sandboxes {
            return Data(#"{"sandboxes":[{"id":"demo-ui","projectId":"demo","displayName":"Login fixture","config":{"harnessConfigId":"demo-harness"},"harnessConfig":{"id":"demo-harness","name":"Subscription agent"},"runtime":{"state":"ready","runtimeState":"running","agentStatus":{"harnessConfigCandidate":"\#(candidate)"}}}]}"#.utf8)
        }
        if request.operation == .harnessChanges {
            previews += 1
            let data = try await demo.perform(request)
            return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "demo-candidate", with: candidate).utf8)
        }
        if request.operation == .defaultProject {
            return Data(#"{"id":"demo","name":"Fixture","defaultHarnessConfigId":"first"}"#.utf8)
        }
        if request.operation == .harnesses {
            return Data(#"{"harnessConfigs":[{"id":"demo-harness","name":"Subscription agent"},{"id":"first","name":"First agent"}]}"#.utf8)
        }
        if request.operation == .saveHarnessChanges {
            saves += 1
            guard request.sandboxID == "demo-ui", request.harnessID == "demo-harness", request.payload?["candidateId"].string == "demo-candidate" else { throw DiscoboxError("Save retargeted") }
            return Data(#"{"state":"saved-handoff-pending","harnessConfigId":"demo-harness","candidateId":"demo-candidate"}"#.utf8)
        }
        return try await demo.perform(request)
    }
}

#endif
