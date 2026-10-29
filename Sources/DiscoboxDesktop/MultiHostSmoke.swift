import AppKit
import SwiftUI
import DiscoboxCore
import GhosttyKit

/// Two independent demo servers intentionally share project/box/exec IDs.
/// The real ConnectedWorkspace is exercised; no sockets, credentials or backend
/// instances are consulted, and all terminal children are synthetic fixtures.
@MainActor enum MultiHostSmoke {
    static func run() async {
        let hub = Connections(polling: false)
        let resources = ConnectionRuntimes()
        let suite = "ai.discobox.smoke.multihost." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let commands = WorkspaceCommands(defaults: defaults)
        defer { hub.disconnectAll(); resources.closeAll(); defaults.removePersistentDomain(forName: suite) }
        do {
            let local = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
            await local.workspace.selectBox("demo-ui")
            try await local.workspace.closeShell("shell-1")
            let studio = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { DemoClient() }
            await studio.workspace.selectBox("demo-ui")
            try await studio.workspace.closeShell("shell-1")
            hub.activate(local.id)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ConnectedWorkspace(connections: hub, runtimes: resources, commands: commands).defaultAppStorage(defaults))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await wait { commands.window === window }
            func identity(_ host: ConnectionSession) -> TerminalIdentity {
                TerminalIdentity(connection: host.workspace.connectionID, endpoint: host.workspace.transportEndpoint, project: host.workspace.projectID!, box: "demo-ui", exec: host.workspace.execID!, demo: true)
            }
            let localID = identity(local)
            let localTerminal = resources.runtime(local.id).terminals.session(localID)
            try await wait { localTerminal.view.window === window }
            try await fillsPane(localTerminal.view)
            window.setContentSize(NSSize(width: 1800, height: 1000))
            try await fillsPane(localTerminal.view)
            commands.performAppShortcut(.switchBox)
            try await wait { window.attachedSheet?.contentView != nil }
            let sheet = window.attachedSheet!
            try await wait { descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Find a box, harness, or repository" } }
            let field = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Find a box, harness, or repository" }!
            sheet.makeFirstResponder(field)
            field.stringValue = "Studio Native macOS workspace"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(for: .milliseconds(150))
            _ = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            try await wait { hub.activeID == studio.id && window.attachedSheet == nil }
            let remoteID = identity(studio)
            let remoteTerminal = resources.runtime(studio.id).terminals.session(remoteID)
            try await wait { remoteTerminal.view.window === window }
            try await fillsPane(remoteTerminal.view)
            guard localTerminal !== remoteTerminal, localTerminal.view.surface != nil else { throw DiscoboxError("Host switch replaced the retained local terminal") }
            commands.perform(.newShell)
            try await wait { studio.workspace.execs.contains(where: \.isShell) }
            guard !local.workspace.execs.contains(where: \.isShell) else { throw DiscoboxError("Remote shell command reached the local server") }
            hub.activate(local.id)
            do { try await wait { localTerminal.view.window === window } }
            catch {
                print("RETURN DEBUG: active=\(hub.activeID) localBox=\(local.workspace.sandboxID ?? "nil") exec=\(local.workspace.execID ?? "nil") live=\(local.workspace.hasLiveTerminal) surface=\(localTerminal.view.surface != nil) ended=\(localTerminal.ended) parent=\(String(describing: localTerminal.view.superview)) localWindow=\(String(describing: localTerminal.view.window))")
                print("RETURN DEBUG: mounted terminals=\(descendants(window.contentView!).compactMap { $0 as? GhosttyTerminalView }.map { "surface=\($0.surface != nil) sameLocal=\($0 === localTerminal.view)" })")
                print("RETURN DEBUG: containers=\(descendants(window.contentView!).filter { String(describing: type(of: $0)).contains("TerminalContainer") }.map { "\(type(of: $0)) children=\($0.subviews.count)" }) layout=\(commands.currentLayout?.selected ?? "nil") keepAgent=\(commands.currentLayout?.keepAgent ?? false) frame=\(window.contentView!.frame)")
                throw error
            }
            guard resources.runtime(local.id).terminals.session(localID) === localTerminal else { throw DiscoboxError("Local terminal was recreated on return") }
            try await fillsPane(localTerminal.view)
            // Start in local Archived, then choose the remote destination in
            // the actual New Box sheet. Success must reveal the remote box.
            local.workspace.filter = .archived
            studio.workspace.filter = .archived
            try await Task.sleep(for: .milliseconds(150))
            commands.performAppShortcut(.newBox)
            try await wait { window.attachedSheet?.contentView != nil }
            let creation = window.attachedSheet!
            try await wait { descendants(creation.contentView!).compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("Studio") } }
            let computer = descendants(creation.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Studio") }!
            let studioIndex = computer.indexOfItem(withTitle: "Studio")
            computer.menu?.performActionForItem(at: studioIndex)
            try await wait { computer.titleOfSelectedItem == "Studio" && !studio.workspace.cachedHarnesses.isEmpty }
            func createButton() -> NSButton? {
                // SwiftUI hosts these button labels instead of NSButton.title.
                descendants(creation.contentView!).compactMap { $0 as? NSButton }.first { $0.cell === creation.defaultButtonCell && $0.isEnabled }
            }
            try await wait { createButton() != nil }
            let create = createButton()!
            create.performClick(nil)
            do { try await wait { window.attachedSheet == nil && hub.activeID == studio.id && studio.workspace.selectedBox?.displayName == "New demo box" } }
            catch {
                print("CREATE DEBUG: sheet=\(window.attachedSheet != nil) activeRemote=\(hub.activeID == studio.id) remoteSelection=\(studio.workspace.sandboxID ?? "nil") remoteNew=\(studio.workspace.sandboxes.filter { $0.displayName == "New demo box" }.count) localNew=\(local.workspace.sandboxes.filter { $0.displayName == "New demo box" }.count) filters=\(local.workspace.filter),\(studio.workspace.filter)")
                throw error
            }
            try await Task.sleep(for: .milliseconds(300))
            guard hub.activeID == studio.id, studio.workspace.filter == .all, local.workspace.filter == .archived else { throw DiscoboxError("Remote creation returned to Archived or changed computers") }
            local.workspace.filter = .all
            await hub.selectBox(.init(connection: local.id, box: "demo-ui"))
            try await wait { localTerminal.view.window === window }
            let localForward = resources.runtime(local.id).forwards.session(box: "demo-ui", workspace: local.workspace)
            _ = resources.runtime(studio.id).forwards.session(box: "demo-ui", workspace: studio.workspace)
            hub.disconnect(studio.id)
            try await wait { remoteTerminal.view.surface == nil }
            guard localTerminal.view.surface != nil, local.workspace.isConnected, !localForward.ports.isEmpty else { throw DiscoboxError("Remote disconnect affected local resources") }
            // An offline selected computer must not block Cmd-K recovery to
            // another live computer.
            hub.activate(studio.id)
            try await Task.sleep(for: .milliseconds(100))
            commands.performAppShortcut(.switchBox)
            try await wait { window.attachedSheet?.contentView != nil }
            let recovery = window.attachedSheet!
            try await wait { descendants(recovery.contentView!).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Find a box, harness, or repository" } }
            let recoveryField = descendants(recovery.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Find a box, harness, or repository" }!
            recoveryField.stringValue = "This computer Native macOS workspace"
            recoveryField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: recoveryField))
            try await Task.sleep(for: .milliseconds(150))
            _ = recoveryField.delegate?.control?(recoveryField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            try await wait { hub.activeID == local.id && window.attachedSheet == nil && localTerminal.view.window === window }
            print("MULTIHOST_SMOKE_OK: composite box switcher + Return, independent terminals, remote creation from Archived, command routing, retained local surface, host-scoped forwarding and disconnect")
            window.orderOut(nil); resources.closeAll(); hub.disconnectAll(); fflush(stdout); exit(0)
        } catch {
            print("MULTIHOST_SMOKE_FAILED: \(error)")
            resources.closeAll(); hub.disconnectAll(); fflush(stdout); exit(1)
        }
    }
    private static func fillsPane(_ view: GhosttyTerminalView) async throws {
        do {
            try await wait {
                guard let parent = view.superview, let surface = view.surface else { return false }
                let pixels = parent.convertToBacking(parent.bounds.size)
                let size = ghostty_surface_size(surface)
                return parent.bounds.width > 400 && parent.bounds.height > 400 &&
                    view.frame == parent.bounds && size.width_px == UInt32(pixels.width.rounded()) && size.height_px == UInt32(pixels.height.rounded())
            }
        } catch {
            throw DiscoboxError("Terminal does not fill its pane: frame=\(view.frame) bounds=\(view.bounds) pane=\(String(describing: view.superview?.bounds))")
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<160 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Multi-host check timed out at line \(line)")
    }
}
