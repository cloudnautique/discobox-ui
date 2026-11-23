#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Drives the real picker and process runner against a recording CLI. All
/// applications, preferences and box data used by the fixture are disposable.
@MainActor enum EditorLauncherSmoke {
    static func run() async {
        do {
            try await verify()
            print("EDITOR_LAUNCHER_SMOKE_OK")
            exit(0)
        } catch { print("EDITOR_LAUNCHER_SMOKE_FAILED: \(error)"); exit(1) }
    }

    private static func verify() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "ai.discobox.editor.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = root.appendingPathComponent("discobox")
        try executable("""
            #!/bin/sh
            printf '%s\\n' "$@" >> "${0%/*}/arguments"
            """, at: cli)
        defaults.set(cli, forKey: "editorDiscoboxCLI")
        defaults.set(true, forKey: "editorSSHConfigured")

        func app(_ editor: BoxEditor) -> URL { root.appendingPathComponent(editor.name + " Fixture.app") }
        func install(_ editor: BoxEditor) throws {
            let launcher = editor.launcher(in: app(editor))
            try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": editor.bundleID, "CFBundlePackageType": "APPL", "CFBundleName": editor.name]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app(editor).appendingPathComponent("Contents/Info.plist"))
            try executable("#!/bin/sh\nexit 0", at: launcher)
        }
        func catalog() -> EditorLauncher { EditorLauncher(defaults: defaults, findApplication: app) }
        let editors = catalog()
        editors.refresh()
        guard editors.apps.isEmpty, editors.preferred == nil else { throw DiscoboxError("Empty editor picker has a default") }
        try install(.zed)
        editors.refresh()
        guard editors.preferred == .zed else { throw DiscoboxError("A single installed editor has no primary action") }

        let profile = ConnectionProfile(name: "Fixture laptop", endpoint: "discobox://fixture-peer")
        let host = ConnectionSession(profile: profile)
        await host.connect(client: DemoClient(), label: profile.endpoint)
        defer { host.disconnect() }
        guard let box = host.inventory.sandboxes.first(where: \.isRunning),
              let project = host.connectionState.projectID else { throw DiscoboxError("Missing running box") }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorPicker(launcher: editors, box: box, host: host, compact: false, enabled: true))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await wait { window.buttonsInContent.contains { $0.title == "Zed" && !$0.isHidden } }
        let primary = window.buttonsInContent.first { $0.title == "Zed" }!
        primary.performClick(nil)
        editors.open(.zed, box: box, host: host, window: window)
        try await wait { !editors.busy }
        let record = root.appendingPathComponent("arguments")
        let args = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        guard args == ["--auto-start-server=false", "--server", profile.endpoint, "--project", project,
                       "tools", "zed", "--program", BoxEditor.zed.launcher(in: app(.zed)).path, "discobox:///" + box.id] else {
            throw DiscoboxError("Primary action launched twice or handed off the wrong target")
        }

        try install(.vscode)
        let restored = catalog()
        restored.refresh()
        guard restored.apps.count == 2, restored.preferred == .zed else { throw DiscoboxError("Editor preference did not survive relaunch") }
        defaults.removeObject(forKey: "lastBoxEditor")
        let fresh = catalog()
        fresh.refresh()
        guard fresh.preferred == nil else { throw DiscoboxError("Picked a default before either editor was chosen") }
        // VS Code was installed after the picker was drawn. Open the actual
        // chevron and select its newly discovered menu item.
        let observer = MenuSelection()
        NotificationCenter.default.addObserver(observer, selector: #selector(MenuSelection.tracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let chooser = window.buttonsInContent.first { $0.accessibilityIdentifier() == "workspace.chooseEditor" }
        chooser?.performClick(nil)
        NotificationCenter.default.removeObserver(observer)
        try await wait { !editors.busy && editors.preferred == .vscode }
        let launches = try String(contentsOf: record, encoding: .utf8)
        guard launches.contains(BoxEditor.vscode.launcher(in: app(.vscode)).path) else {
            throw DiscoboxError("The menu did not launch the newly installed editor")
        }
        try fm.removeItem(at: BoxEditor.zed.launcher(in: app(.zed)))
        restored.refresh()
        guard restored.preferred == .vscode else { throw DiscoboxError("Removed editor stayed selected") }

        guard let stopped = host.inventory.sandboxes.first(where: { BoxAction.start.isAvailable(for: $0) }) else { throw DiscoboxError("Missing stopped box") }
        restored.open(.vscode, box: stopped, host: host, window: window)
        try await wait { window.attachedSheet != nil }
        host.disconnect()
        guard let confirm = window.attachedSheet?.buttonsInContent.first(where: { $0.title.hasPrefix("Start & Open") }) else {
            throw DiscoboxError("Stopped editor target skipped confirmation")
        }
        confirm.performClick(nil)
        try await wait { window.attachedSheet?.buttonsInContent.contains { $0.title == "OK" } == true }
        window.attachedSheet?.buttonsInContent.first { $0.title == "OK" }?.performClick(nil)
        try await wait { !restored.busy }
        guard try String(contentsOf: record, encoding: .utf8) == launches else {
            throw DiscoboxError("A stale start confirmation launched the editor")
        }
    }

    @MainActor private final class MenuSelection: NSObject {
        @objc func tracking(_ notice: Notification) {
            guard let menu = notice.object as? NSMenu, menu.item(withTitle: "Locate Editor…") != nil else { return }
            perform(#selector(selectEditor(_:)), with: menu, afterDelay: 0.1, inModes: [.eventTracking, .default, .common])
        }
        @objc func selectEditor(_ menu: NSMenu) {
            let index = menu.indexOfItem(withTitle: "VS Code")
            if index >= 0 { menu.performActionForItem(at: index) }
            menu.cancelTracking()
        }
    }

    private static func executable(_ script: String, at url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiscoboxError("Timed out waiting for editor fixture")
    }
}

private extension NSWindow {
    var buttonsInContent: [NSButton] {
        func buttons(_ view: NSView) -> [NSButton] { [view].compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons) }
        return contentView.map(buttons) ?? []
    }
}
#endif
