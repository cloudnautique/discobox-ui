import AppKit
import GhosttyKit
import SwiftUI
import DiscoboxCore

/// Runs against the demo workspace only. Events enter the real AppKit event
/// queue so this exercises the monitor before Ghostty's responder methods.
@MainActor enum CommandSmoke {
    static func run(workspace: Workspace, commands: WorkspaceCommands, terminals: TerminalStore, client: DemoClient) async {
        let saved = commands.bindings
        let savedShortcuts = commands.appShortcuts
        commands.appShortcuts = AppShortcuts()
        defer { commands.bindings = saved; commands.appShortcuts = savedShortcuts }
        do {
            guard workspace.isDemo else { throw Failure("offline workspace required") }
            try await wait { commands.window != nil }
            let window = commands.window!
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await wait {
                if !window.isKeyWindow { window.makeKey(); window.orderFrontRegardless() }
                return window.isKeyWindow
            }
            try await wait { window.firstResponder is GhosttyTerminalView }
            print("COMMAND: focused"); fflush(stdout)
            // An arriving/resolved credential and leader hints must never take
            // rows away from the harness (inline TUIs track their cursor rows).
            try await Task.sleep(for: .milliseconds(400))
            window.contentView!.layoutSubtreeIfNeeded()
            try await wait { terminalViews(window.contentView!).first?.window === window }
            let harness = terminalViews(window.contentView!).first!
            let terminalRect = harness.convert(harness.bounds, to: nil)
            print("COMMAND: terminal rect \(terminalRect), content \(window.contentLayoutRect), window \(window.frame), view \(window.contentView!.bounds)"); fflush(stdout)
            guard abs(terminalRect.maxY - (window.contentLayoutRect.maxY - 42)) < 1,
                  abs(terminalRect.minY - (window.contentLayoutRect.minY + 31)) < 1 else {
                throw Failure("terminal obscures tab header or status footer: \(terminalRect), content \(window.contentLayoutRect)")
            }
            func toolbarFrames() -> [String: NSRect] {
                Dictionary((window.toolbar?.visibleItems ?? []).compactMap { item in
                    guard let view = item.view else { return nil }
                    return (item.itemIdentifier.rawValue, view.convert(view.bounds, to: nil))
                }, uniquingKeysWith: { first, _ in first })
            }
            let fixedToolbar = toolbarFrames()
            guard fixedToolbar.count >= 2,
                  let rightEdge = fixedToolbar.values.map(\.maxX).max(),
                  rightEdge > window.contentView!.bounds.width - 60 else {
                throw Failure("toolbar actions are not pinned to the right edge: \(fixedToolbar)")
            }
            for (hidden, inspector) in [(true, false), (true, true), (false, true), (false, false)] {
                commands.focusMode = hidden
                commands.showInspector = inspector
                try await Task.sleep(for: .milliseconds(450))
                window.contentView!.layoutSubtreeIfNeeded()
                for (id, original) in fixedToolbar {
                    guard let current = toolbarFrames()[id], abs(current.minX - original.minX) < 1 else {
                        throw Failure("toolbar control moved when toggling panels: \(id), \(original), \(String(describing: toolbarFrames()[id]))")
                    }
                }
                let rect = harness.convert(harness.bounds, to: nil)
                guard abs(rect.minY - (window.contentLayoutRect.minY + 31)) < 1 else {
                    throw Failure("footer height changed with sidebar/inspector")
                }
            }
            await workspace.refreshUsage()
            if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] {
                capture(window, path: directory + "/usage-sidebar.png")
            }
            print("COMMAND: fixed toolbar, unified footer, inline usage section OK"); fflush(stdout)
            let originalBounds = harness.bounds
            let originalGrid = ghostty_surface_size(harness.surface!)
            for pending in [true, false, true, false] {
                await client.setPendingRequests(pending)
                await workspace.refreshApprovals()
                commands.hint = pending ? "ctrl+a  …   Esc to cancel" : nil
                try await Task.sleep(for: .milliseconds(150))
                window.contentView!.layoutSubtreeIfNeeded()
                let grid = ghostty_surface_size(harness.surface!)
                guard harness.bounds == originalBounds,
                      grid.columns == originalGrid.columns, grid.rows == originalGrid.rows else {
                    throw Failure("approval/leader status changed terminal geometry: \(originalBounds) -> \(harness.bounds); \(originalGrid.columns)x\(originalGrid.rows) -> \(grid.columns)x\(grid.rows)")
                }
            }
            print("COMMAND: approval and leader status preserve terminal geometry"); fflush(stdout)
            window.makeFirstResponder(harness)
            commands.bindings = CommandBindings(leader: "ctrl+d")
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await wait { commands.hint != nil }
            post(window, code: 1, text: "S", plain: "s", flags: .shift)
            try await Task.sleep(for: .milliseconds(100))
            post(window, code: 29, text: "0")
            try await wait { commands.showInspector && commands.inspectorSection == "services" }
            commands.showInspector = false
            print("COMMAND: services"); fflush(stdout)
            // Bindings are active across the workspace, not in editable fields.
            let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
            window.contentView!.addSubview(field)
            window.makeFirstResponder(field)
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await Task.sleep(for: .milliseconds(150))
            guard commands.hint == nil else { throw Failure("leader captured in text field") }
            field.removeFromSuperview()
            window.makeFirstResponder(nil)
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await wait { commands.hint != nil }
            post(window, code: 0, text: "a")
            try await wait { commands.tab == .terminal && workspace.selectedExec?.primary == true && window.firstResponder is GhosttyTerminalView }
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await wait { commands.hint != nil }
            post(window, code: 1, text: "s")
            try await wait { workspace.execID == "shell-1" && !workspace.isOpeningShell }
            try await wait { terminalViews(window.contentView!).count == 2 }
            let splitViews = terminalViews(window.contentView!)
            guard splitViews.allSatisfy({ $0.bounds.width > 150 && $0.bounds.height > 200 }) else { throw Failure("split terminal has collapsed bounds") }
            guard let divider = splitViews[0].ancestorSplitView else { throw Failure("native split divider missing") }
            let oldWidth = splitViews[0].bounds.width
            divider.setPosition(divider.bounds.width * 0.6, ofDividerAt: 0)
            try await wait { abs(splitViews[0].bounds.width - oldWidth) > 10 }
            let frames = splitViews.map { $0.convert($0.bounds, to: window.contentView) }
            guard !frames[0].intersects(frames[1]) else { throw Failure("split terminals overlap") }
            if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] {
                capture(window, path: directory + "/split-shell.png")
            }
            print("COMMAND: split"); fflush(stdout)
            let beforeMaximize = commands.currentLayout!.selected
            let beforeFocus = commands.currentLayout!.agentFocused
            let beforeSidebar = commands.focusMode
            commands.showInspector = true
            commands.perform(.focus)
            try await wait {
                guard commands.isAgentMaximized, let view = terminalViews(window.contentView!).first,
                      terminalViews(window.contentView!).count == 1 else { return false }
                let frame = view.convert(view.bounds, to: nil)
                return frame.minX >= 0 && frame.maxX <= window.contentLayoutRect.maxX + 2
            }
            guard commands.focusMode == beforeSidebar && !commands.showInspector,
                  commands.currentLayout?.selected == "agent",
                  terminalViews(window.contentView!).first === splitViews[0] else {
                throw Failure("maximization did not isolate the existing agent")
            }
            commands.perform(.focus)
            try await wait { !commands.isAgentMaximized && terminalViews(window.contentView!).count == 2 }
            guard commands.focusMode == beforeSidebar && commands.showInspector,
                  commands.currentLayout?.selected == beforeMaximize,
                  commands.currentLayout?.agentFocused == beforeFocus else {
                throw Failure("maximization did not restore the previous layout")
            }
            commands.showInspector = false
            print("COMMAND: maximize and restore agent preserve layout and terminal identity"); fflush(stdout)

            let originalBox = workspace.sandboxID
            for _ in 0..<3 {
                commands.perform(.nextBox)
                try await wait { workspace.sandboxID != originalBox }
                commands.perform(.previousBox)
                do { try await wait { workspace.sandboxID == originalBox && terminalViews(window.contentView!).count == 2 } }
                catch { throw Failure("box restore: selected=\(commands.currentLayout?.selected ?? "nil") terminals=\(terminalViews(window.contentView!).count)") }
                try await wait {
                    terminalViews(window.contentView!).allSatisfy { view in
                        guard let surface = view.surface else { return false }
                        let actual = ghostty_surface_size(surface), expected = view.convertToBacking(view.bounds.size)
                        return expected.width > 0 && actual.width_px == UInt32(expected.width.rounded()) && actual.height_px == UInt32(expected.height.rounded())
                    }
                }
            }
            guard terminalViews(window.contentView!).contains(where: { $0 === splitViews[0] }) else { throw Failure("box switching replaced the retained harness surface") }
            print("COMMAND: repeated box remount sizes OK"); fflush(stdout)
            try await wait { window.firstResponder is GhosttyTerminalView }
            commands.cancelPrefix()
            // Unknown chords are consumed; Escape cancels the prefix.
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await wait { commands.hint != nil }
            post(window, code: 53, text: "\u{1b}")
            try await wait { commands.hint == nil }
            // Audit binding uses the current leader; help is a native app shortcut.
            post(window, code: 2, text: "\u{4}", plain: "d", flags: .control)
            try await wait { commands.hint != nil }
            post(window, code: 0, text: "A", plain: "a", flags: .shift)
            try await wait { commands.currentLayout?.selected == "audit" }
            try await wait { terminalViews(window.contentView!).count == 1 }
            guard terminalViews(window.contentView!).first === splitViews[0] else { throw Failure("audit replaced the harness") }
            try await wait { window.firstResponder is NSTextView }
            // Exercise the same initial-divider component in a deterministic
            // native split fixture, without depending on SwiftUI List internals.
            let detailWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            detailWindow.contentView = NSHostingView(rootView: VSplitView {
                Text("Events").frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                Text("Message body").frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    .background(InitialSplitFraction(fraction: 2.0 / 3.0))
            })
            detailWindow.orderFront(nil)
            try await wait { splits(detailWindow.contentView!).contains(where: { $0.arrangedSubviews.count == 2 }) }
            let detailSplit = splits(detailWindow.contentView!).first(where: { $0.arrangedSubviews.count == 2 })!
            try await wait { abs(detailSplit.arrangedSubviews[1].frame.height / detailSplit.bounds.height - 1.0 / 3.0) < 0.05 }
            detailSplit.setPosition(300, ofDividerAt: 0)
            detailWindow.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            guard abs(detailSplit.arrangedSubviews[0].frame.height - 300) < 2 else { throw Failure("initial detail sizing overrode divider drag") }
            detailWindow.orderOut(nil)
            print("COMMAND: Audit search focus and one-third detail sizing OK"); fflush(stdout)
            // With the agent pinned, wraparound stays in the tool tabs.
            post(window, code: 30, text: "}", plain: "]", flags: [.command, .shift])
            try await wait { commands.currentLayout?.selected == "exec:shell-1" }
            guard terminalViews(window.contentView!).contains(where: { $0 === splitViews[0] }) else { throw Failure("pinned agent remounted on tab wrap") }
            post(window, code: 33, text: "{", plain: "[", flags: [.command, .shift])
            try await wait { commands.currentLayout?.selected == "audit" && window.firstResponder is NSTextView }
            // Cmd-{ returns to the shell; Cmd-[ moves focus
            // between its two panes without changing the selected tab.
            post(window, code: 33, text: "{", plain: "[", flags: [.command, .shift])
            try await wait { commands.currentLayout?.selected == "exec:shell-1" && terminalViews(window.contentView!).count == 2 }
            guard terminalViews(window.contentView!).contains(where: { $0 === splitViews[1] }) else { throw Failure("tab switch replaced retained shell") }
            try await wait { window.firstResponder === splitViews[1] }
            post(window, code: 33, text: "[", flags: .command)
            try await wait { window.firstResponder === splitViews[0] }
            guard commands.currentLayout?.selected == "exec:shell-1" else { throw Failure("pane navigation changed tab") }
            post(window, code: 30, text: "]", flags: .command)
            try await wait { window.firstResponder === splitViews[1] }
            post(window, code: 30, text: "}", plain: "]", flags: [.command, .shift])
            try await wait { commands.currentLayout?.selected == "audit" && terminalViews(window.contentView!).count == 1 }
            try await wait { !(window.firstResponder is GhosttyTerminalView) }
            // Layout controls support side-by-side and a single maximized tab.
            commands.currentLayout?.sideBySide = true
            commands.currentLayout?.open("exec:shell-1")
            try await wait { terminalViews(window.contentView!).count == 2 }
            try await Task.sleep(for: .milliseconds(200))
            let sideFrames = terminalViews(window.contentView!).map { $0.convert($0.bounds, to: window.contentView) }
            guard abs(sideFrames[0].minY - sideFrames[1].minY) < 1 else { throw Failure("side-by-side headers misaligned") }
            commands.currentLayout?.keepAgent = false
            do { try await wait { terminalViews(window.contentView!).count == 1 } }
            catch { throw Failure("single tab: count=\(terminalViews(window.contentView!).count) selected=\(commands.currentLayout?.selected ?? "nil") split=\(commands.currentLayout?.isSplit ?? false)") }
            guard terminalViews(window.contentView!).first === splitViews[1] else { throw Failure("maximize selected wrong terminal") }
            commands.currentLayout?.keepAgent = true
            commands.currentLayout?.sideBySide = false
            commands.currentLayout?.open("audit")
            if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] {
                try await Task.sleep(for: .milliseconds(400))
                capture(window, path: directory + "/split-audit.png")
            }
            print("COMMAND: tabs, pane shortcuts, keep-agent and layout modes OK"); fflush(stdout)
            let snapshot = try await workspace.auditSnapshot(box: workspace.sandboxID!)
            guard snapshot.records.count == 2 else { throw Failure("audit fixture missing") }
            post(window, code: 4, text: "h", flags: .command)
            try await wait { commands.showCommands }
            commands.showCommands = false
            try await wait { window.attachedSheet == nil }
            post(window, code: 45, text: "n", flags: .command)
            try await wait { commands.showCreateBox && window.attachedSheet != nil }
            commands.showCreateBox = false
            try await wait { window.attachedSheet == nil }
            post(window, code: 40, text: "k", flags: .command)
            try await wait { commands.choosingBox && window.attachedSheet != nil }
            let chooser = window.attachedSheet!
            try await wait { chooser.firstResponder is NSTextView }
            let candidates = workspace.switcherBoxes
            guard candidates.map(\.id) == ["demo-tests", "demo-ui", "demo-api"] else { throw Failure("switcher state priority incorrect") }
            post(chooser, code: 125, text: "\u{f701}")
            post(chooser, code: 125, text: "\u{f701}")
            post(chooser, code: 36, text: "\r")
            try await wait { window.attachedSheet == nil && workspace.sandboxID == candidates[2].id }
            post(window, code: 40, text: "k", flags: .command)
            try await wait { window.attachedSheet?.firstResponder is NSTextView }
            let searchSheet = window.attachedSheet!
            (searchSheet.firstResponder as! NSTextView).insertText("claude discobox-ui", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(150))
            post(searchSheet, code: 36, text: "\r")
            try await wait { window.attachedSheet == nil && workspace.sandboxID == "demo-ui" }
            print("COMMAND: box chooser arrows, Return, harness/repository search OK"); fflush(stdout)
            commands.appShortcuts[.newBox] = "cmd+option+n"
            post(window, code: 45, text: "n", flags: [.command, .option])
            try await wait { commands.showCreateBox && window.attachedSheet != nil }
            commands.showCreateBox = false
            try await wait { window.attachedSheet == nil }
            commands.appShortcuts = AppShortcuts()
            print("COMMAND: Cmd-N, Cmd-K and remapped app shortcut OK"); fflush(stdout)
            print("COMMAND: sheets"); fflush(stdout)
            commands.showTools = true
            try await wait { window.attachedSheet != nil }
            commands.showTools = false
            try await wait { window.attachedSheet == nil }
            commands.perform(.files)
            try await wait { terminalViews(window.contentView!).count == 1 && commands.currentLayout?.selected == "files" }
            commands.showFiles = false
            print("COMMAND: files"); fflush(stdout)
            await client.setPendingRequests(true)
            await workspace.refreshApprovals()
            guard workspace.approvals.count == 1 else { throw Failure("demo approval missing") }
            commands.showApprovals = true
            try await wait { window.attachedSheet != nil }
            let approvalWindow = window.attachedSheet!
            try await Task.sleep(for: .milliseconds(400))
            if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] { capture(approvalWindow, path: directory + "/approval.png") }
            approvalWindow.makeFirstResponder(nil)
            post(approvalWindow, code: 36, text: "\r")
            try await wait { workspace.approvals.isEmpty && window.attachedSheet == nil }
            guard await client.lastApprovalAction == "deny" else { throw Failure("approval form default was not Deny") }
            print("COMMAND: single request opens directly; Return denies without review step"); fflush(stdout)
            window.makeKeyAndOrderFront(nil)
            try await workspace.closeShell("shell-1")
            guard !workspace.execs.contains(where: { $0.id == "shell-1" }) else { throw Failure("closed shell remains") }
            commands.tab = .terminal
            commands.bindings = saved
            if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] {
                try await Task.sleep(for: .milliseconds(400))
                capture(window, path: directory + "/workspace.png")
                let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                settings.title = "Discobox · Keybindings"
                settings.contentView = NSHostingView(rootView: KeybindingSettings().environment(commands))
                settings.center(); settings.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                capture(settings, path: directory + "/keybindings.png")
                settings.orderOut(nil)
            }
            terminals.closeAll()
            print("COMMAND_SMOKE_OK: remapped leader, multi-key services, text-field isolation, agent navigation, demo shell, split terminal bounds, cancellation, tab navigation, pane focus, keep-agent layouts and aligned headers, Cmd-H help, new-box prompt, tools sheet, files drawer, approval sheet and resolution, shell close")
            fflush(stdout); exit(0)
        } catch {
            print("COMMAND_SMOKE_FAILED: \(error)"); fflush(stdout)
            terminals.closeAll(); exit(1)
        }
    }
    private static func splits(_ view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits($0) }
    }
    private static func terminalViews(_ view: NSView) -> [GhosttyTerminalView] {
        if let terminal = view as? GhosttyTerminalView { return [terminal] }
        return view.subviews.flatMap { terminalViews($0) }
    }
    private static func capture(_ window: NSWindow, path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        do { try process.run(); process.waitUntilExit() } catch { print("Screenshot unavailable: \(error)"); return }
        if process.terminationStatus != 0, let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("Saved view snapshot (Metal content may be omitted): \(path)")
        }
    }
    private static func post(_ window: NSWindow, code: UInt16, text: String, plain: String? = nil, flags: NSEvent.ModifierFlags = []) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: plain ?? text, isARepeat: false, keyCode: code)!
            NSApp.postEvent(event, atStart: false)
        }
    }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw Failure("timed out waiting for command state at line \(line)")
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private extension NSView {
    var ancestorSplitView: NSSplitView? {
        var parent = superview
        while let candidate = parent {
            if let split = candidate as? NSSplitView { return split }
            parent = candidate.superview
        }
        return nil
    }
}
