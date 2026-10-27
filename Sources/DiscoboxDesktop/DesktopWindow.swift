import SwiftUI
import WebKit
import DiscoboxCore

@MainActor @Observable final class DesktopWindows {
    private var sessions: [String: DesktopSession] = [:]
    func open(url: URL, box: Sandbox) {
        if let session = sessions[box.id], !session.closed, session.source == url {
            session.window.makeKeyAndOrderFront(nil); return
        }
        sessions.removeValue(forKey: box.id)?.close()
        let session = DesktopSession(source: url, title: box.displayName)
        sessions[box.id] = session
        session.window.makeKeyAndOrderFront(nil)
    }
    func close(box: String) { sessions.removeValue(forKey: box)?.close() }
    func retainRunningBoxes(_ boxes: [Sandbox]) {
        let ids = Set(boxes.filter(\.isRunning).map(\.id))
        for id in Array(sessions.keys) where !ids.contains(id) { close(box: id) }
    }
    func closeAll() { for session in sessions.values { session.close() }; sessions.removeAll() }
}

@MainActor @Observable final class DesktopSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let source: URL
    let window: NSWindow
    let web: DesktopWebView
    var ready = false
    var error: String?
    var terminalShortcuts = false
    var syncClipboard = true
    private(set) var closed = false
    private var remoteText: String?
    private var copyRequested = false
    private let pasteboard: NSPasteboard
    private var origin: URL?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(source: URL, title: String, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.source = source
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = DesktopWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Desktop — " + title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: DesktopWindowView(session: self))
        window.center()
        web.session = self
        web.navigationDelegate = self
        config.userContentController.add(self, name: "discoboxDesktop")
        process.executableURL = CompanionLocation.executable
        process.arguments = ["--desktop", "--desktop-url", source.absoluteString]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        do { try process.run() } catch { self.error = error.localizedDescription }
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty else { ready = false; if error == nil { error = "Desktop connection ended. Close and reopen this window to reconnect." }; return }
        buffer.append(data)
        guard buffer.count < 65536 else { error = "Invalid desktop launcher response."; return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let response = try? JSONDecoder().decode([String: String].self, from: line) else { continue }
            if let failure = response["error"] { error = failure }
            if let raw = response["url"], let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1", url.port != nil {
                origin = url
                web.load(URLRequest(url: url))
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, sameOrigin(url),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": ready = body["value"] as? Bool ?? false
        case "editing": web.pageEditing = body["value"] as? Bool ?? false
        case "error": error = body["value"] as? String
        case "clipboard":
            guard let text = body["value"] as? String, text.utf8.count <= 1024 * 1024 else { return }
            remoteText = text
            if syncClipboard || copyRequested { writeClipboard(text) }; copyRequested = false
        default: break
        }
    }
    private func sameOrigin(_ url: URL) -> Bool {
        guard let origin else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if sameOrigin(url) { return .allow }
        if navigationAction.navigationType == .linkActivated && ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        return .cancel
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; error = "Desktop viewer stopped. Use Reconnect to reload it." }
    func command(_ key: String) {
        guard ready else { return }
        if key == "c" { copyRequested = true; if let remoteText { writeClipboard(remoteText) } }
        evaluate("window.discoboxNative.command(key, terminal)", args: ["key": key, "terminal": terminalShortcuts])
    }
    func paste() {
        guard ready, let text = pasteboard.string(forType: .string) else { return }
        guard text.utf8.count <= 1024 * 1024 else { error = "Paste is limited to 1 MiB of text."; return }
        evaluate("window.discoboxNative.paste(text, terminal)", args: ["text": text, "terminal": terminalShortcuts])
    }
    private func evaluate(_ script: String, args: [String: Any]) {
        error = nil
        web.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.error = error.localizedDescription }
        }
        window.makeFirstResponder(web)
    }
    private func writeClipboard(_ text: String) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    func reload() { ready = false; error = nil; web.reload() }
    func windowWillClose(_ notification: Notification) { close() }
    func close() {
        guard !closed else { return }
        closed = true; ready = false
        web.stopLoading(); web.loadHTMLString("", baseURL: nil)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "discoboxDesktop")
        web.navigationDelegate = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
    }
}

@MainActor final class DesktopWebView: WKWebView {
    weak var session: DesktopSession?
    var pageEditing = false
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !pageEditing, session?.ready == true, let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self),
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": session?.paste(); return true
        case "c": session?.command("c"); return true
        case "x": session?.command("x"); return true
        case "a": session?.command("a"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private struct DesktopSurface: NSViewRepresentable {
    let web: DesktopWebView
    func makeNSView(context: Context) -> DesktopWebView { web }
    func updateNSView(_ nsView: DesktopWebView, context: Context) {}
}
private struct DesktopWindowView: View {
    @Bindable var session: DesktopSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !session.ready { ProgressView().controlSize(.small) }
                Text(session.ready ? "Connected" : "Connecting…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { session.command("c") }.disabled(!session.ready).help("Copy selected remote text to the Mac (⌘C)")
                Button("Paste") { session.paste() }.disabled(!session.ready).help("Paste Mac clipboard text into the desktop (⌘V)")
                Toggle("Terminal shortcuts", isOn: $session.terminalShortcuts).toggleStyle(.checkbox)
                    .help("Use Ctrl-Shift-C/V for Linux terminals. Leave off for browsers and other apps.")
                Menu {
                    Toggle("Sync remote clipboard to Mac", isOn: $session.syncClipboard)
                    Button("Reconnect") { session.reload() }
                    Button("Open in Browser") { NSWorkspace.shared.open(session.source) }
                    Button("Full Screen") { session.window.toggleFullScreen(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(10).background(.bar)
            if let error = session.error { Notice(text: error, symbol: "exclamationmark.triangle") }
            DesktopSurface(web: session.web)
        }.frame(minWidth: 750, minHeight: 500)
    }
}
