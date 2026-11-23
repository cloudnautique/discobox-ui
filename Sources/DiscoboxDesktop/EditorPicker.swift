import SwiftUI
import AppKit
import DiscoboxCore

/// AppKit asks for the menu at click time, so installing an editor while
/// Discobox is open also works on the first visit to the picker.
struct EditorPicker: NSViewRepresentable {
    let launcher: EditorLauncher
    let box: Sandbox?
    let host: ConnectionSession
    let compact: Bool
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let primary = coordinator.primary
        let menu = coordinator.menuButton
        for button in [primary, menu] {
            button.isBordered = false
            button.font = .preferredFont(forTextStyle: .callout)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.target = coordinator
        }
        primary.action = #selector(Coordinator.openPreferred)
        menu.action = #selector(Coordinator.chooseEditor)
        let stack = NSStackView(views: [primary, menu])
        stack.spacing = 2
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        let coordinator = context.coordinator
        coordinator.picker = self
        let preferred = launcher.preferred
        let button = coordinator.primary
        button.isHidden = preferred == nil
        button.isEnabled = enabled
        if let preferred {
            button.title = compact ? "" : preferred.name
            button.image = launcher.icon(preferred)
            let action = box?.isRunning == false ? "Start and open" : "Open"
            let label = "\(action) \(box?.displayName ?? "box") in \(preferred.name)"
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        let menu = coordinator.menuButton
        menu.isEnabled = enabled
        menu.title = preferred == nil ? (compact ? "⌄" : "Editor ⌄") : ""
        menu.image = NSImage(systemSymbolName: preferred == nil ? "chevron.left.forwardslash.chevron.right" : "chevron.down", accessibilityDescription: nil)
        menu.toolTip = "Choose editor"
        menu.setAccessibilityLabel("Choose editor")
        menu.setAccessibilityIdentifier("workspace.chooseEditor")
        button.setAccessibilityIdentifier("workspace.openEditor")
    }

    @MainActor final class Coordinator: NSObject {
        var picker: EditorPicker
        let primary = NSButton()
        let menuButton = NSButton()
        init(_ picker: EditorPicker) { self.picker = picker }

        @objc func openPreferred() {
            guard let editor = picker.launcher.preferred, let box = picker.box, let window = primary.window else { return }
            picker.launcher.open(editor, box: box, host: picker.host, window: window)
        }

        @objc func chooseEditor() {
            guard let window = menuButton.window, let box = picker.box else { return }
            let launcher = picker.launcher
            let host = picker.host
            let generation = host.connectionState.connectionID
            launcher.refresh()
            let menu = NSMenu()
            if launcher.apps.isEmpty {
                menu.addItem(withTitle: "No supported editor found", action: nil, keyEquivalent: "")
            }
            for editor in BoxEditor.allCases where launcher.apps[editor] != nil {
                let title = box.isRunning ? editor.name : "Start & Open in " + editor.name + "…"
                let item = menu.addItem(withTitle: title, action: #selector(selectItem(_:)), keyEquivalent: "")
                item.target = self
                item.image = launcher.icon(editor)
                item.state = launcher.preferred == editor ? .on : .off
                item.representedObject = editor.rawValue
            }
            menu.addItem(.separator())
            let locate = menu.addItem(withTitle: "Locate Editor…", action: #selector(selectItem(_:)), keyEquivalent: "")
            locate.target = self
            selected = nil
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: menuButton)
            if selected === locate {
                Task { await launcher.locateEditor(in: window) }
            } else if generation == host.connectionState.connectionID, let id = selected?.representedObject as? String, let editor = BoxEditor(rawValue: id) {
                launcher.open(editor, box: box, host: host, window: window)
            }
            selected = nil
        }

        private var selected: NSMenuItem?
        @objc private func selectItem(_ item: NSMenuItem) { selected = item }
    }
}
