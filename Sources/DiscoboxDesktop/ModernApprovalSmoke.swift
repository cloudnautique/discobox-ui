import AppKit
import SwiftUI
import DiscoboxCore

/// Real controls and delayed, read-only fixtures for remote approval recovery.
@MainActor enum ModernApprovalSmoke {
    static func verify() async throws {
        for mode in ["use", "sharing", "both", "failure", "new", "deny"] {
            let client = RemoteApprovalFixture(mode: mode)
            let workspace = Workspace()
            await workspace.connect(client: client, label: "Remote fixture", demo: true)
            await workspace.refreshApprovals()
            guard let item = workspace.approvals.first else { throw DiscoboxError("Missing remote approval fixture") }
            var closed = false
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ScopedCredentialApprovalView(item: item, onClose: { closed = true }).environment(workspace))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); workspace.disconnect() }
            try await wait { menus(window).contains { $0.numberOfItems == 3 && $0.isEnabled } }
            let credential = menus(window).first(where: { $0.numberOfItems == 3 })!
            guard credential.itemTitle(at: 0) == "+ New credential…", segments(window).isEmpty,
                  action(window)?.isEnabled == false, await client.answers == 0 else { throw DiscoboxError("Approval form has intermediate decisions or grants access before an explicit footer action") }
            if mode == "deny" {
                footer(window)[2].performClick(nil)
                try await waitAsync { await client.answers == 1 }
                try await wait { closed }
                continue
            }
            if mode == "new" {
                credential.menu?.performActionForItem(at: 0)
                try await wait { fields(window).contains { $0 is NSSecureTextField } }
                guard let name = fields(window).first(where: { $0.placeholderString == "Name" }),
                      let token = fields(window).first(where: { $0 is NSSecureTextField }) else { throw DiscoboxError("Inline credential form did not open") }
                for (field, value) in [(name, "New fixture account"), (token, "fixture-token")] {
                    window.makeFirstResponder(field)
                    field.stringValue = value
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                }
                try await wait { saveButton(window)?.isEnabled == true }
                guard action(window)?.isEnabled == false, await client.answers == 0 else { throw DiscoboxError("New credential bypassed explicit approval") }
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(150))
                    try capture(window, name: "inline-credential-new-" + name)
                }
                saveButton(window)?.performClick(nil)
                try await waitAsync { await client.stores == 1 }
                try await wait { menus(window).contains { $0.titleOfSelectedItem == "New fixture account" } }
                guard await client.answers == 0 else { throw DiscoboxError("Saving a credential approved the request") }
            } else { credential.menu?.performActionForItem(at: 2) }
            if mode == "failure" {
                try await waitAsync { await client.failures == 1 }
                try await wait { menus(window).contains { $0.titleOfSelectedItem == "Fixture account" && $0.isEnabled } }
                guard action(window)?.isEnabled == false else { throw DiscoboxError("Failed preview enabled approval") }
                footer(window).dropFirst().first?.performClick(nil)
            }
            try await wait { action(window)?.isEnabled == true }
            if mode == "use" { try capture(window, name: "credential-footer-approve") }
            action(window)?.performClick(nil)
            try await waitAsync { await client.answers == 1 }
            try await wait { footer(window).count == 2 && action(window)?.isEnabled == true }
            action(window)?.performClick(nil)
            guard closed, await client.answers == 1 else { throw DiscoboxError("Remote approval did not complete once") }
        }
        print("MODERN_APPROVAL_SMOKE_OK: footer-only use/sharing/combined approval and denial, inline credential creation without a grant, preserved selection after preview failure, and one explicit decision per request")
    }
    private static func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let root = window.contentView,
              let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }
    private static func fields(_ window: NSWindow) -> [NSTextField] { window.contentView.map { views($0).compactMap { $0 as? NSTextField } } ?? [] }
    private static func saveButton(_ window: NSWindow) -> NSButton? {
        guard let root = window.contentView else { return nil }
        return views(root).compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) && $0.enclosingScrollView != nil && $0.bounds.width > 80 && $0.bounds.width < 190 }
            .max { $0.convert($0.bounds, to: root).maxX < $1.convert($1.bounds, to: root).maxX }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func menus(_ window: NSWindow) -> [NSPopUpButton] { window.contentView.map { views($0).compactMap { $0 as? NSPopUpButton } } ?? [] }
    private static func segments(_ window: NSWindow) -> [NSSegmentedControl] { window.contentView.map { views($0).compactMap { $0 as? NSSegmentedControl } } ?? [] }
    private static func action(_ window: NSWindow) -> NSButton? { window.contentView.flatMap { views($0).compactMap { $0 as? NSButton }.first { $0.cell === window.defaultButtonCell } } }
    private static func footer(_ window: NSWindow) -> [NSButton] {
        guard let root = window.contentView, let action = action(window) else { return [] }
        let y = action.convert(action.bounds, to: root).midY
        return views(root).compactMap { $0 as? NSButton }.filter { abs($0.convert($0.bounds, to: root).midY - y) < 2 }
            .sorted { $0.convert($0.bounds, to: root).midX < $1.convert($1.bounds, to: root).midX }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<160 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Remote approval controls did not recover")
    }
    private static func waitAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<160 { if await condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Remote approval fixture did not finish")
    }
}

private actor RemoteApprovalFixture: DiscoboxClient {
    let demo = DemoClient()
    let mode: String
    var failures = 0
    var answers = 0
    var stores = 0
    init(mode: String) { self.mode = mode }
    private var ask: JSONValue {
        var fields: [String: JSONValue] = ["id": .string("remote-ask"), "sandboxId": .string("demo-ui"), "status": .string("pending"), "name": .string("Repository access"), "envName": .string("GH_TOKEN"),
                 "justification": .string("Read repository issues; share access only when requested.")]
        if mode != "sharing" { fields["use"] = .object(["routes": .array((0..<30).map { .object(["hosts": .array([.string("api.example.test")]), "paths": .array([.string("/repos/example/project/path-\($0)/**")])]) })]) }
        if mode != "use" { fields["delegate"] = .object(["routes": .array([.object(["hosts": .array([.string("api.example.test")])])])]) }
        return .object(fields)
    }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .approvals {
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(answers == 0 ? [.object(["kind": .string("credential"), "credential": ask])] : [])]))
        }
        if request.operation == .approvalContext {
            try await Task.sleep(for: .milliseconds(100))
            if mode == "failure", failures == 0, request.payload != nil { failures += 1; throw DiscoboxError("Remote preview timed out; reload to retry.") }
            return try JSONEncoder().encode(JSONValue.object([
                "request": ask, "fingerprint": .string("remote-fingerprint"), "held": .array([]), "bindings": .array([]),
                "secrets": .array([.object(["id": .string("fixture-secret"), "name": .string("Fixture account"), "maxBindingTTLSeconds": .number(1800)])]
                    + (stores == 0 ? [] : [.object(["id": .string("created-secret"), "name": .string("New fixture account"), "maxBindingTTLSeconds": .number(3600)])]))
            ]))
        }
        if request.operation == .createSecret {
            guard request.payload?["name"].string == "New fixture account", request.payload?["value"]["token"].string == "fixture-token",
                  request.payload?["routes"].array == ask["use"]["routes"].array + ask["delegate"]["routes"].array else { throw DiscoboxError("Wrong inline credential payload") }
            stores += 1
            return Data(#"{"id":"created-secret"}"#.utf8)
        }
        if request.operation == .answer {
            guard request.requestID == "remote-ask" else { throw DiscoboxError("Wrong approval request") }
            if mode == "deny" {
                guard request.action == "deny", request.payload == .object([:]) else { throw DiscoboxError("Deny sent approval data") }
            } else {
                let approval = request.payload?["approval"] ?? .null
                guard request.action == "approve", approval["secretId"].string == (stores == 0 ? "fixture-secret" : "created-secret"),
                      request.payload?["contextFingerprint"].string == "remote-fingerprint" else { throw DiscoboxError("Wrong remote approval payload") }
                for part in ["use", "delegate"] {
                    if ask[part] == .null { guard approval[part] == .null else { throw DiscoboxError("Approved unrequested access") }; continue }
                    guard approval[part]["decision"].string == "approve", approval[part]["scope"].string == "routes", approval[part]["raw"] == .null else { throw DiscoboxError("Approval widened scope or delivery") }
                }
            }
            answers += 1
            return Data("{}".utf8)
        }
        return try await demo.perform(request)
    }
}
