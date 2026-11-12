import AppKit
import SwiftUI
import DiscoboxCore

/// Offline regression for a use-only request over delegated access.
@MainActor enum BindingConflictSmoke {
    static func run() async {
        do {
            try await verify()
            print("BINDING_CONFLICT_SMOKE_OK: replacement blocked, explicit addition edits only the draft, fresh review still required; no approval/binding writes")
            fflush(stdout); exit(0)
        } catch { print("BINDING_CONFLICT_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func verify() async throws {
        let client = BindingConflictFixture(), workspace = Workspace()
        await workspace.connect(client: client, label: "Offline binding fixture", demo: true)
        await workspace.refreshApprovals()
        guard let item = workspace.approvals.first else { throw DiscoboxError("Missing request fixture") }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ApprovalSheet(item: item).environment(workspace))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); workspace.disconnect() }
        guard let root = window.contentView else { throw DiscoboxError("Missing review view") }
        try await wait { views(root).contains { $0 is NSSegmentedControl } }
        let decision = views(root).compactMap { $0 as? NSSegmentedControl }.first!
        decision.selectedSegment = 1
        decision.sendAction(decision.action, to: decision.target)
        try await wait { addButton(window) != nil && addButton(window)?.isEnabled == true }
        guard submit(window)?.isEnabled == false else { throw DiscoboxError("Conflicting replacement was submittable") }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            try capture(window, name: "binding-conflict-" + theme)
        }
        addButton(window)?.performClick(nil)
        try await wait { addButton(window) == nil }
        let candidate = await client.candidate
        guard candidate["use"]["as"].string == "add", candidate["use"]["scope"].string == "routes",
              candidate["use"]["raw"] == .null, submit(window)?.isEnabled == false,
              await client.writes == 0, workspace.approvals.count == 1 else {
            throw DiscoboxError("Addition changed access, widened scope, lost review gating or answered the request")
        }
        try capture(window, name: "binding-addition-review")
    }
    private static func submit(_ window: NSWindow) -> NSButton? { buttons(window).first { $0.cell === window.defaultButtonCell } }
    private static func addButton(_ window: NSWindow) -> NSButton? {
        // SwiftUI proxy nodes carry AX labels rather than the native NSButton.
        // The explicit draft-change action is the form's only wide text button.
        buttons(window).first { !($0 is NSPopUpButton) && $0.bounds.width > 230 }
    }
    private static func buttons(_ window: NSWindow) -> [NSButton] { window.contentView.map { views($0).compactMap { $0 as? NSButton } } ?? [] }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Binding conflict UI timed out at line \(line)")
    }
    private static func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let root = window.contentView,
              let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private actor BindingConflictFixture: DiscoboxClient {
    private let demo = DemoClient()
    private(set) var candidate: JSONValue = .null
    private(set) var writes = 0
    private let ask: JSONValue = .object([
        "id": .string("request"), "sandboxId": .string("demo-ui"), "name": .string("Repository access"), "envName": .string("TOKEN"), "status": .string("pending"),
        "use": .object(["routes": .array([.object(["hosts": .array([.string("api.example.test")]), "methods": .array([.string("GET")])])])])
    ])
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .approvals {
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array([.object(["kind": .string("credential"), "credential": ask])])]))
        }
        if request.operation == .approvalContext {
            candidate = request.payload ?? .null
            let replacing = candidate["use"]["decision"].string == "approve" && candidate["use"]["as"].string != "add"
            let conflict: JSONValue = .object(["part": .string("use"), "bindingId": .string("existing"), "parentId": .string("parent"), "canAdd": .bool(true),
                "message": .string("This box’s existing access was delegated by another box. This approval cannot replace that grant.")])
            let held: JSONValue = .object(["bindingId": .string("existing"), "secretId": .string("token"), "secretName": .string("Repository access"), "envVar": .string("TOKEN"), "use": .bool(true), "from": .string("sandbox"), "fromId": .string("demo-ui")])
            let secret: JSONValue = .object(["id": .string("token"), "name": .string("Repository access"), "maxBindingTTLSeconds": .number(1800)])
            let body: JSONValue = .object(["request": ask, "secrets": .array([secret]), "held": .array([held]), "bindings": .array([]), "fingerprint": .string("fixture-review"), "conflicts": .array(replacing ? [conflict] : [])])
            return try JSONEncoder().encode(body)
        }
        if request.operation == .answer || request.operation == .createSecret { writes += 1; throw DiscoboxError("Fixture forbids all writes") }
        return try await demo.perform(request)
    }
}
