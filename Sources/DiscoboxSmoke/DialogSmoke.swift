#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Targeted demo-only checks: no server, Keychain, box creation, or port probes.
@MainActor enum DialogSmoke {
    static func run(workspace: ConnectionSession, commands: WorkspaceCommands, terminals: TerminalStore) async {
        do {
            guard workspace.connectionState.isDemo else { throw DiscoboxError("Demo workspace required") }
            try await wait { commands.window != nil }
            let window = commands.window!
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            _ = try await workspace.catalog.harnesses()
            // This fixture checks search/selection. MultiHostSmoke covers the
            // stopped-box prompt and its explicit Start & Open decision.
            try await workspace.commands.performBoxAction(.start, boxID: "demo-api", connection: workspace.connectionState.connectionID)
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
                guard let target = workspace.inventory.sandboxes.first(where: { $0.id != workspace.selection.sandboxID }) else { throw DiscoboxError("Missing demo target") }
                field.stringValue = target.displayName
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await Task.sleep(for: .milliseconds(100))
                print("DIALOG: Box switcher \(iteration) searchable in \(switchStart.duration(to: .now))")
                _ = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
                try await wait { window.attachedSheet == nil && workspace.selection.sandboxID == target.id }
            }
            try await verifyResourcesResize(workspace)
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
    private struct ResourcesFixture: View {
        let session: ConnectionSession
        @State private var presented = false
        var body: some View {
            Color.clear.onAppear { presented = true }
                .sheet(isPresented: $presented) {
                    PoolResourcesView(computer: "Fixture computer").environment(session)
                }
        }
    }

    private static func verifyResourcesResize(_ session: ConnectionSession) async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.contentView = NSHostingView(rootView: ResourcesFixture(session: session))
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        try await wait { parent.attachedSheet?.contentView != nil }
        let sheet = parent.attachedSheet!
        let root = sheet.contentView!
        guard sheet.styleMask.contains(.resizable),
              sheet.contentMinSize.width < sheet.contentMaxSize.width,
              sheet.contentMinSize.height < sheet.contentMaxSize.height else {
            throw DiscoboxError("Resources sheet has a fixed size")
        }
        func doneButton() -> NSButton? {
            // SwiftUI draws the button labels itself. Done is the trailing
            // button outside the report's scroll view and dismisses the sheet.
            guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first else { return nil }
            let report = scroll.convert(scroll.bounds, to: root)
            return descendants(root).compactMap { $0 as? NSButton }.filter {
                let bounds = $0.convert($0.bounds, to: root)
                return root.bounds.contains(bounds) && (root.isFlipped ? bounds.minY >= report.maxY : bounds.maxY <= report.minY)
            }.max { $0.convert($0.bounds, to: root).midX < $1.convert($1.bounds, to: root).midX }
        }
        try await wait { descendants(root).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows > 0 } }
        let table = descendants(root).compactMap { $0 as? NSTableView }.first { $0.numberOfRows > 0 }!
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        for size in [NSSize(width: 700, height: 420), NSSize(width: 900, height: 700)] {
            sheet.setContentSize(size)
            try await wait {
                root.layoutSubtreeIfNeeded()
                return root.bounds.size == size && table.selectedRow == 0 && doneButton() != nil
            }
        }
        doneButton()?.performClick(nil)
        try await wait { parent.attachedSheet == nil }
        print("DIALOG: Resources sheet resizes in both dimensions with its Done button visible")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Dialog did not become ready at line \(line)")
    }
}

#endif
