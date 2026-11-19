#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Real controls and delayed, read-only fixtures for remote approval recovery.
@MainActor enum ModernApprovalSmoke {
    static func verify() async throws {
        try await verifySharedCredentialSave()
        for mode in ["use", "sharing", "both", "failure", "new", "new-edited", "deny"] {
            let client = RemoteApprovalFixture(mode: mode)
            let workspace = ConnectionSession()
            await workspace.connect(client: client, label: "Remote fixture", demo: true)
            await workspace.approvalStore.refreshApprovals()
            guard let item = workspace.approvalStore.approvals.first else { throw DiscoboxError("Missing remote approval fixture") }
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
            if mode == "new" || mode == "new-edited" {
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
                if mode == "new-edited" {
                    // The native buttons host SwiftUI-drawn labels. The route
                    // action precedes the inline form's Cancel and Save row.
                    let inline = views(window.contentView!).compactMap { $0 as? NSButton }.filter {
                        !($0 is NSPopUpButton) && $0.enclosingScrollView === token.enclosingScrollView
                    }
                    guard inline.count == 3, let edit = inline.first else { throw DiscoboxError("Missing inline route controls") }
                    edit.performClick(nil)
                    try await wait { window.attachedSheet != nil }
                    let editor = window.attachedSheet!
                    guard let root = editor.contentView else { throw DiscoboxError("Missing route editor content") }
                    let buttons = views(root).compactMap { $0 as? NSButton }
                    guard let apply = buttons.max(by: { $0.convert($0.bounds, to: root).midX < $1.convert($1.bounds, to: root).midX }) else {
                        throw DiscoboxError("Missing route editor footer")
                    }
                    try await wait { apply.isEnabled }
                    guard let text = editor.contentView.flatMap({ views($0).compactMap { $0 as? NSTextView }.first(where: { $0.isEditable && $0.string.contains("api.example.test") }) }) else {
                        throw DiscoboxError("Route editor did not load the requested routes")
                    }
                    text.insertText("\nPOST api.example.test/issues/*/comments", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
                    apply.performClick(nil)
                    try await wait { window.attachedSheet == nil }
                    guard await client.stores == 0, await client.answers == 0 else { throw DiscoboxError("Editing draft routes wrote to the fixture") }
                }
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
    static func verifyWorkspace(connections: Connections, commands: WorkspaceCommands) async throws {
        let client = RemoteApprovalFixture(mode: "use")
        let session = try await connections.connect(.thisComputer, demo: true) { client }
        await session.approvalStore.refreshApprovals()
        try await session.commands.performBoxAction(.start, boxID: "demo-api", connection: session.connectionState.connectionID)
        await connections.selectBox(.init(connection: session.id, box: "demo-api"))
        // Keep a different terminal selected so the answered row disappears
        // instead of moving to the pinned selection section.
        connections.browser.searchText = "Native macOS workspace"
        connections.browser.activityFilter = .needsYou
        try await wait { commands.window?.contentView != nil }
        let window = commands.window!
        window.makeKeyAndOrderFront(nil)
        // The fixture has one matching box, after the pinned terminal and group header.
        func reviewButton() -> NSButton? {
            guard connections.browserBoxes.map(\.box.id) == ["demo-ui"] else { return nil }
            guard let table = views(window.contentView!).compactMap({ $0 as? NSTableView }).first,
                  table.numberOfRows > 0,
                  let row = table.rowView(atRow: table.numberOfRows - 1, makeIfNecessary: false) else { return nil }
            return views(row).compactMap { $0 as? NSButton }.first { $0.isEnabled }
        }
        try await wait { reviewButton() != nil }
        reviewButton()?.performClick(nil)
        try await wait { window.attachedSheet.flatMap(action)?.isEnabled == true }
        let sheet = window.attachedSheet!
        action(sheet)?.performClick(nil)
        try await wait { menus(sheet).contains { $0.numberOfItems == 3 && $0.isEnabled } }
        menus(sheet).first { $0.numberOfItems == 3 }?.menu?.performActionForItem(at: 2)
        try await wait { footer(sheet).count == 4 && action(sheet)?.isEnabled == true }
        action(sheet)?.performClick(nil)
        try await waitAsync { await client.answers == 1 }
        try await wait { !connections.browserBoxes.contains(where: { $0.box.id == "demo-ui" }) && session.approvalStore.approvals.isEmpty }
        try await wait { window.attachedSheet == nil || footer(sheet).count == 2 && action(sheet)?.isEnabled == true }
        guard window.attachedSheet === sheet else { throw DiscoboxError("Removing the answered box row dismissed its receipt") }
        action(sheet)?.performClick(nil)
        try await wait { window.attachedSheet === sheet && sheet.defaultButtonCell == nil }
        guard let close = views(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "\u{1b}" }) else {
            throw DiscoboxError("Empty inbox has no Close button")
        }
        close.performClick(nil)
        try await wait { window.attachedSheet == nil }
        guard await client.answers == 1 else { throw DiscoboxError("Approval was submitted more than once") }
    }

    private static func verifySharedCredentialSave() async throws {
        let client = RemoteApprovalFixture(mode: "limits")
        let workspace = ConnectionSession()
        await workspace.connect(client: client, label: "Fixture", demo: true)
        let secret: JSONValue = .object(["id": .string("fixture"), "name": .string("Example credential"), "maxBindingTTLSeconds": .number(3600)])
        var receipt: JSONValue?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CredentialDetailsView(request: .init(secret: secret, connection: workspace.connectionState.connectionID),
                                                                           saved: { receipt = $0 }).environment(workspace))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); workspace.disconnect() }
        try await wait { fields(window).contains { $0.placeholderString == "Seconds" } }
        let field = fields(window).first { $0.placeholderString == "Seconds" }!
        guard action(window)?.isEnabled != true else { throw DiscoboxError("An unchanged credential enabled Save") }
        window.makeFirstResponder(field)
        field.stringValue = "7200"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        for confirm in [false, true] {
            try await wait { action(window)?.isEnabled == true }
            action(window)?.performClick(nil)
            try await wait { window.attachedSheet.flatMap(action)?.isEnabled == true }
            let sheet = window.attachedSheet!
            guard await client.stores == 0 else { throw DiscoboxError("Credential limits were saved before confirmation") }
            if confirm {
                action(sheet)?.performClick(nil)
            } else {
                guard let cancel = footer(sheet).first, cancel !== action(sheet) else { throw DiscoboxError("Missing Cancel action") }
                cancel.performClick(nil)
            }
            try await wait { window.attachedSheet == nil }
        }
        try await wait { receipt?["maxBindingTTLSeconds"] == .number(7200) }
        guard await client.stores == 1 else { throw DiscoboxError("Expected one confirmed credential update") }
        print("CREDENTIAL_SAVE_SMOKE_OK: Save previews changes, Cancel preserves the edit, and confirmation writes once")
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
    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<160 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Remote approval controls did not recover at line \(line)")
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
        if request.operation == .updateSecretLimits, mode == "limits" {
            guard request.secretID == "fixture", request.payload?["expectedSecret"]["maxBindingTTLSeconds"] == .number(3600),
                  request.payload?["limits"] == .object(["maxBindingTTLSeconds": .number(7200)]) else {
                throw DiscoboxError("Incorrect shared-limit update")
            }
            stores += 1
            return Data(#"{"id":"fixture","maxBindingTTLSeconds":7200}"#.utf8)
        }
        if request.operation == .credentialRoutes {
            let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/discobox-desktop-bridge")
            return try await CompanionClient(executable: binary, endpoint: "unix:///tmp/missing-fixture.sock").perform(request)
        }
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
            var routes = ask["use"]["routes"].array + ask["delegate"]["routes"].array
            if mode == "new-edited" {
                routes.append(.object(["hosts": .array([.string("api.example.test")]), "methods": .array([.string("POST")]), "paths": .array([.string("/issues/*/comments")])]))
            }
            guard request.payload?["name"].string == "New fixture account", request.payload?["value"]["token"].string == "fixture-token",
                  request.payload?["routes"].array == routes else { throw DiscoboxError("Wrong inline credential payload") }
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
            if mode == "use" {
                let grant: JSONValue = .object(["mode": .string("replace"), "delivery": .string("proxy"),
                    "routeLists": .array([.object(["source": .string("request"), "routes": ask["use"]["routes"]]),
                                          .object(["source": .string("credential"), "routes": .array([])])])])
                return try JSONEncoder().encode(JSONValue.object(["use": .object(["outcome": .string("approved"),
                    "approvedScope": .string("routes"), "grant": grant])]))
            }
            return Data("{}".utf8)
        }
        return try await demo.perform(request)
    }
}

#endif
