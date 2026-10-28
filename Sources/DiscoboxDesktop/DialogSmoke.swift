import AppKit
import DiscoboxCore

/// Targeted demo-only checks: no server, Keychain, box creation, or port probes.
@MainActor enum DialogSmoke {
    static func run(workspace: Workspace, commands: WorkspaceCommands, terminals: TerminalStore) async {
        do {
            guard workspace.isDemo else { throw DiscoboxError("Demo workspace required") }
            try await wait { commands.window != nil }
            let window = commands.window!
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            _ = try await workspace.harnesses()
            for iteration in 1...2 {
                let start = ContinuousClock.now
                commands.performAppShortcut(.newBox)
                try await wait { window.attachedSheet?.contentView != nil }
                let sheet = window.attachedSheet!
                try await wait { descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.contains { $0.isEditable && $0.isEnabled } }
                guard descendants(sheet.contentView!).compactMap({ $0 as? NSTextField }).contains(where: { $0.isEditable && $0.isEnabled }) else {
                    throw DiscoboxError("New Box text fields are disabled")
                }
                print("DIALOG: New Box \(iteration) ready in \(start.duration(to: .now))")
                commands.showCreateBox = false
                try await wait { window.attachedSheet == nil }
                let switchStart = ContinuousClock.now
                commands.performAppShortcut(.switchBox)
                try await wait { window.attachedSheet?.contentView != nil }
                let chooser = window.attachedSheet!
                try await wait { descendants(chooser.contentView!).contains { ($0 as? NSTextField)?.placeholderString == "Find a box, harness, or repository" } }
                let field = descendants(chooser.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Find a box, harness, or repository" }!
                chooser.makeFirstResponder(field)
                guard let target = workspace.sandboxes.first(where: { $0.id != workspace.sandboxID }) else { throw DiscoboxError("Missing demo target") }
                field.stringValue = target.displayName
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await Task.sleep(for: .milliseconds(100))
                print("DIALOG: Box switcher \(iteration) searchable in \(switchStart.duration(to: .now))")
                _ = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
                try await wait { window.attachedSheet == nil && workspace.sandboxID == target.id }
            }
            let originalSection = commands.inspectorSection
            let selected = commands.currentLayout?.selected
            commands.showInspector = false
            commands.performAppShortcut(.toggleInspector)
            try await wait { commands.showInspector }
            commands.performAppShortcut(.toggleInspector)
            try await wait { !commands.showInspector }
            commands.perform(.services)
            try await wait { commands.showInspector && commands.inspectorSection == "services" }
            guard commands.currentLayout?.selected == selected,
                  commands.currentLayout?.tools.contains("services") != true else {
                throw DiscoboxError("Services changed the workspace tab")
            }
            commands.showInspector = false
            commands.inspectorSection = originalSection
            print("DIALOG: Inspector toggle and Services preserve workspace tabs")
            print("DIALOG_SMOKE_PASSED")
            terminals.closeAll(); fflush(stdout); exit(0)
        } catch {
            print("DIALOG_SMOKE_FAILED: \(error)")
            terminals.closeAll(); fflush(stdout); exit(1)
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Dialog did not become ready at line \(line)")
    }
}
