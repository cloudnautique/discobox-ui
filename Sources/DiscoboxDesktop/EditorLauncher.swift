import AppKit
import DiscoboxCore
import UniformTypeIdentifiers

enum BoxEditor: String, CaseIterable {
    case vscode, zed

    var name: String { self == .vscode ? "VS Code" : "Zed" }
    var bundleID: String { self == .vscode ? "com.microsoft.VSCode" : "dev.zed.Zed" }
    func launcher(in app: URL) -> URL {
        app.appendingPathComponent(self == .vscode ? "Contents/Resources/app/bin/code" : "Contents/MacOS/cli")
    }
}

@MainActor @Observable final class EditorLauncher {
    private(set) var apps: [BoxEditor: URL] = [:]
    private(set) var busy = false
    private let findApplication: (BoxEditor) -> URL?
    private var icons: [BoxEditor: NSImage] = [:]
    private let defaults: UserDefaults
    private var lastEditor: String?
    private static let lastKey = "lastBoxEditor"
    private static let cliKey = "editorDiscoboxCLI"

    init(defaults: UserDefaults = .standard,
         findApplication: @escaping (BoxEditor) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) }) {
        self.findApplication = findApplication
        self.defaults = defaults
        lastEditor = defaults.string(forKey: Self.lastKey)
    }

    var preferred: BoxEditor? {
        if let lastEditor, let editor = BoxEditor(rawValue: lastEditor), apps[editor] != nil { return editor }
        return apps.count == 1 ? apps.keys.first : nil
    }

    func refresh() {
        var found: [BoxEditor: URL] = [:]
        for editor in BoxEditor.allCases {
            let located = defaults.url(forKey: "editorApp." + editor.rawValue)
            let system = findApplication(editor)
            found[editor] = [located, system].compactMap { $0 }.first {
                Bundle(url: $0)?.bundleIdentifier == editor.bundleID &&
                FileManager.default.isExecutableFile(atPath: editor.launcher(in: $0).path)
            }
        }
        guard found != apps else { return }
        icons = found.mapValues { url in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let sized = icon.copy() as? NSImage ?? icon
            sized.size = NSSize(width: 18, height: 18)
            return sized
        }
        apps = found
    }

    func icon(_ editor: BoxEditor) -> NSImage? { icons[editor] }

    func locateEditor(in window: NSWindow) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.message = "Choose Visual Studio Code or Zed."
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        guard let editor = BoxEditor.allCases.first(where: { $0.bundleID == Bundle(url: url)?.bundleIdentifier }),
              FileManager.default.isExecutableFile(atPath: editor.launcher(in: url).path) else {
            _ = await ask("Unsupported editor", "Choose the Visual Studio Code or Zed application with its command-line launcher.", ["OK"], window)
            return
        }
        defaults.set(url, forKey: "editorApp." + editor.rawValue)
        refresh()
    }

    func available(_ host: ConnectionSession, box: Sandbox) -> Bool {
        let state = host.connectionState
        return !busy && state.isConnected && state.connectionError == nil && !state.isDemo &&
            !box.isArchived && !box.isDeleted && !box.lifecycle.isTransitioning &&
            (box.isRunning || BoxAction.start.isAvailable(for: box)) &&
            !host.pending.pendingBoxActions.contains(box.id) && !host.pending.clearingPools.contains(box.poolId ?? "")
    }

    func open(_ editor: BoxEditor, box: Sandbox, host: ConnectionSession, window: NSWindow) {
        guard available(host, box: box), let project = host.connectionState.projectID else { return }
        let intent = BoxStartIntent(connection: host.connectionState, inventory: host.inventory, pending: host.pending,
                                    commands: host.commands, box: box, computer: host.profile.displayName)
        let profile = host.profile
        busy = true
        Task {
            defer { busy = false }
            do {
                refresh()
                guard let app = apps[editor] else { throw DiscoboxError("Locate \(editor.name) in the editor menu and try again.") }
                if profile.isRemote && profile.directOnly == true {
                    throw DiscoboxError("The Discobox CLI cannot enforce this connection’s direct-only Iroh setting for editor SSH sessions.")
                }
                guard let cli = await findCLI(window) else { return }
                guard await confirmSSHSetup(in: window) else { return }
                @MainActor func checkTarget() throws {
                    guard intent.isCurrent, host.connectionState.projectID == project, host.connectionState.connectionError == nil,
                          intent.canStart, intent.currentBox?.lifecycle.isTransitioning == false else {
                        throw DiscoboxError("The box or its connection changed. Check its current state and try again.")
                    }
                }
                try checkTarget()
                if !intent.alreadyRunning {
                    let action = "Start & Open in " + editor.name
                    guard await ask("Start “\(box.displayName)”?", "Start this box on \(intent.computer) and open its workspace in \(editor.name).", [action, "Cancel"], window) == .alertFirstButtonReturn else { return }
                    try checkTarget()
                    guard await intent.start() else { throw DiscoboxError(intent.failure ?? "The box could not be started.") }
                    try checkTarget()
                }
                guard intent.alreadyRunning else { throw DiscoboxError("The box is still starting. Open it in the editor once it is running.") }
                let result = try await EditorCommand.run(cli, arguments: EditorCommand.arguments(editor, app: app, profile: profile, project: project, boxID: box.id), profile: profile)
                if result.status != 0 {
                    let detail = result.text.isEmpty ? "Discobox exited with status \(result.status)." : result.text
                    let lower = detail.lowercased()
                    if profile.isRemote && ["not authorized", "not enrolled", "unauthorized", "access refused", "403"].contains(where: lower.contains) {
                        let peer = try await EditorCommand.run(cli, arguments: ["admin", "peer", "id"], profile: profile)
                        if peer.status == 0, peer.text.hasPrefix("d1-"), peer.text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                            if await ask("Authorize the Discobox CLI on \(intent.computer)", "The editor connects using this Mac’s CLI identity. Run the enrollment command on \(intent.computer), then open “\(box.displayName)” again.", ["Copy Enrollment Command", "Cancel"], window) == .alertFirstButtonReturn {
                                copy(ComputerIdentity.enrollmentCommand(peerID: peer.text, name: ComputerIdentity.systemName + " CLI", localServer: true))
                            }
                            return
                        }
                    }
                    if lower.contains("unknown command") || lower.contains("unknown flag") {
                        throw DiscoboxError("Update the Discobox CLI to a version that supports tools " + editor.rawValue + ".\n\n" + detail)
                    }
                    throw DiscoboxError(detail)
                }
                lastEditor = editor.rawValue
                defaults.set(editor.rawValue, forKey: Self.lastKey)
            } catch {
                _ = await ask("Couldn’t open “\(box.displayName)” in \(editor.name)", intent.computer + "\n\n" + error.localizedDescription, ["OK"], window)
            }
        }
    }

    private func findCLI(_ window: NSWindow) async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = [defaults.url(forKey: Self.cliKey)].compactMap { $0 } +
            (paths + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"])
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("discobox") }
        if let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return cli }
        let panel = NSOpenPanel()
        panel.message = "Locate the installed discobox CLI that provides the VS Code and Zed tools."
        panel.prompt = "Use CLI"
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return nil }
        guard FileManager.default.isExecutableFile(atPath: url.path), url.lastPathComponent == "discobox" else {
            _ = await ask("Choose the discobox executable", "Install the Discobox CLI or locate its executable and try again.", ["OK"], window)
            return nil
        }
        defaults.set(url, forKey: Self.cliKey)
        return url
    }

    private func confirmSSHSetup(in window: NSWindow) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/state")
        let preference = state.appendingPathComponent("discobox/cli/ssh/include-preference")
        if defaults.bool(forKey: "editorSSHConfigured") || (try? String(contentsOf: preference, encoding: .utf8)) == "enabled" { return true }
        let answer = await ask("Use Discobox SSH aliases for editors", "Run discobox admin ssh-config enable to add managed Include lines to your SSH configuration and refresh configured servers. If your SSH aliases already work, continue with your existing configuration.", ["Copy Setup Command", "Already Configured", "Cancel"], window)
        if answer == .alertSecondButtonReturn { defaults.set(true, forKey: "editorSSHConfigured"); return true }
        if answer == .alertFirstButtonReturn { copy("discobox admin ssh-config enable") }
        return false
    }

    private func ask(_ title: String, _ detail: String, _ buttons: [String], _ window: NSWindow) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        for button in buttons { alert.addButton(withTitle: button) }
        return await alert.beginSheetModal(for: window)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
