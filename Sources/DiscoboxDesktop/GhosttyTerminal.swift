import AppKit
import SwiftUI
import GhosttyKit
import DiscoboxCore

/// One runtime for the process; surfaces and their PTY children belong to the
/// session store, rather than to transient SwiftUI view values.
@MainActor final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    private(set) var app: ghostty_app_t?
    private(set) var error: String?

    private init() {
        let resources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] ?? Bundle.main.resourceURL!.appendingPathComponent("ghostty").path
        setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        guard ghostty_init(0, nil) == 0, let config = ghostty_config_new() else {
            error = "Ghostty could not initialize. Rebuild the app bundle."; return
        }
        defer { ghostty_config_free(config) }
        // Use embedding defaults, not the user's standalone Ghostty commands.
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { if let app = GhosttyRuntime.shared.app { ghostty_app_tick(app) } }
        }
        runtime.action_cb = { _, target, action in
            MainActor.assumeIsolated {
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface,
                      let userdata = ghostty_surface_userdata(surface) else { return false }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                if action.tag == GHOSTTY_ACTION_RENDERER_HEALTH {
                    if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
                        view.failed?("Ghostty reported a rendering failure. Reconnect this terminal.")
                    }
                    return true
                }
                return false
            }
        }
        runtime.read_clipboard_cb = { userdata, _, state in
            MainActor.assumeIsolated {
                guard let userdata else { return }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return }
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            }
        }
        runtime.confirm_read_clipboard_cb = { userdata, text, state, kind in
            MainActor.assumeIsolated {
                guard let userdata, let text else { return }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return }
                let alert = NSAlert()
                alert.messageText = kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? "Paste into terminal?" : "Allow terminal clipboard access?"
                alert.informativeText = "The terminal requested clipboard content. Pasting multiple lines can execute commands."
                alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    ghostty_surface_complete_clipboard_request(surface, text, state, true)
                }
            }
        }
        runtime.write_clipboard_cb = { _, text, _, confirm in
            MainActor.assumeIsolated {
                guard let text else { return }
                if confirm {
                    let alert = NSAlert(); alert.messageText = "Allow terminal to replace the clipboard?"
                    alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(cString: text), forType: .string)
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            MainActor.assumeIsolated {
                guard let userdata else { return }
                Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue().ended?()
            }
        }
        app = ghostty_app_new(&runtime, config)
        if app == nil { error = "Ghostty could not create its renderer." }
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didResignActiveNotification, object: nil)
    }
    @objc private func focusChanged() { if let app { ghostty_app_set_focus(app, NSApp.isActive) } }
}

struct TerminalIdentity: Hashable {
    let connection: UUID
    let endpoint: String
    let project: String
    let box: String
    let exec: String
    let demo: Bool
}

@MainActor @Observable final class TerminalSession {
    let view: GhosttyTerminalView
    var ended = false
    var error: String?
    private var monitor: Task<Void, Never>?
    convenience init(identity: TerminalIdentity) {
        let args = identity.demo ? ["--terminal-demo"] : ["--attach", "--endpoint", identity.endpoint, "--project", identity.project, "--box", identity.box, "--exec", identity.exec]
        self.init(arguments: args)
    }
    init(arguments: [String]) {
        view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.ended = { [weak self] in self?.ended = true }
        view.failed = { [weak self] message in self?.error = message }
        // Ghostty executes command through a shell. Quote every argument,
        // including the bundled path; endpoint text must never become shell code.
        let command = ([CompanionLocation.executable.path] + arguments).map(Self.quote).joined(separator: " ")
        error = view.start(command: command)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let surface = self.view.surface else { return }
                if ghostty_surface_process_exited(surface) { self.ended = true; return }
            }
        }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func close() { monitor?.cancel(); monitor = nil; view.close() }
}

@MainActor @Observable final class TerminalStore {
    private var sessions: [TerminalIdentity: TerminalSession] = [:]
    func session(_ identity: TerminalIdentity) -> TerminalSession {
        if let value = sessions[identity] { return value }
        let value = TerminalSession(identity: identity); sessions[identity] = value; return value
    }
    func focus(_ identity: TerminalIdentity) {
        guard let view = sessions[identity]?.view else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.isKeyWindow else { return }
            window.makeFirstResponder(view)
        }
    }
    func reconnect(_ identity: TerminalIdentity) {
        sessions.removeValue(forKey: identity)?.close()
    }
    func closeBox(_ box: String, connection: UUID) {
        for identity in Array(sessions.keys) where identity.box == box && identity.connection == connection {
            sessions.removeValue(forKey: identity)?.close()
        }
    }
    func closeAll() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }
}

struct LiveTerminal: View {
    let identity: TerminalIdentity
    var focused = true
    var onFocus: (() -> Void)?
    @Environment(TerminalStore.self) private var store
    var body: some View {
        let session = store.session(identity)
        VStack(spacing: 0) {
            if let error = session.error { Notice(text: error, symbol: "exclamationmark.triangle") }
            TerminalSurface(view: session.view, focused: focused, onFocus: onFocus).id(identity)
            if session.ended || session.error != nil {
                HStack {
                    Label("Terminal disconnected", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Reconnect") { store.reconnect(identity) }
                }.font(.caption).padding(8)
            }
        }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let view: GhosttyTerminalView
    let focused: Bool
    let onFocus: (() -> Void)?
    final class Coordinator { var focused = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { TerminalContainerView() }
    func updateNSView(_ container: NSView, context: Context) {
        view.onFocus = onFocus
        (container as? TerminalContainerView)?.requestedFocus = focused
        if focused && (!context.coordinator.focused || view.superview !== container) {
            DispatchQueue.main.async { [weak container, weak view] in
                guard let container, let view, view.superview === container, container.window != nil,
                      (container as? TerminalContainerView)?.requestedFocus == true else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        context.coordinator.focused = focused
        guard view.superview !== container else { return }
        for child in container.subviews { child.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.needsLayout = true
        DispatchQueue.main.async { [weak container, weak view] in
            guard let container, let view, view.superview === container, container.window != nil else { return }
            container.layoutSubtreeIfNeeded()
            view.refreshPresentation()
        }
    }
    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        for child in container.subviews { child.removeFromSuperview() }
    }
}

@MainActor private final class TerminalContainerView: NSView {
    var requestedFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedFocus, let window = self.window,
                  let terminal = self.subviews.first as? GhosttyTerminalView else { return }
            window.makeFirstResponder(terminal)
        }
    }
    override func layout() {
        super.layout()
        guard let terminal = subviews.first as? GhosttyTerminalView else { return }
        // Frame changes schedule a resize; routine SwiftUI layout passes should
        // not force a synchronous renderer draw on the main thread.
        if terminal.frame != bounds { terminal.frame = bounds }
    }
}

@MainActor final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    var ended: (() -> Void)?
    var onFocus: (() -> Void)?
    var failed: ((String) -> Void)?
    private var marked = NSAttributedString(string: "")
    private var inputText: [String]?
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func start(command: String) -> String? {
        let runtime = GhosttyRuntime.shared
        guard let app = runtime.app else { return runtime.error }
        wantsLayer = true
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 13
        config.wait_after_command = true
        // No local shell integration: the child exclusively transports remote bytes.
        surface = command.withCString { command in
            config.command = command
            return ghostty_surface_new(app, &config)
        }
        guard surface != nil else { return "Could not create the Ghostty terminal surface." }
        resizeSurface()
        return nil
    }
    func close() {
        if let surface { ghostty_surface_free(surface); self.surface = nil }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleResize() }
    override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); scheduleResize() }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleResize()
        if let surface { ghostty_surface_refresh(surface) }
    }
    override func layout() { super.layout(); scheduleResize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleResize() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface {
            ghostty_surface_set_occlusion(surface, window != nil)
            if window == nil { ghostty_surface_set_focus(surface, false) }
            scheduleResize()
            if window != nil { ghostty_surface_refresh(surface) }
        }
    }
    func refreshPresentation() {
        guard window != nil, let surface else { return }
        scheduleResize()
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }
    private var contentScale: CGFloat?
    private var resizeScheduled = false
    private func scheduleResize() {
        guard window != nil, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeSurface()
        }
    }
    private func resizeSurface() {
        guard window != nil, let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if contentScale != scale {
            ghostty_surface_set_content_scale(surface, scale, scale)
            contentScale = scale
        }
        let pixels = convertToBacking(bounds.size)
        let current = ghostty_surface_size(surface)
        let width = UInt32(pixels.width.rounded())
        let height = UInt32(pixels.height.rounded())
        if current.width_px != width || current.height_px != height {
            ghostty_surface_set_size(surface, width, height)
            ghostty_surface_refresh(surface)
        }
    }
    override func becomeFirstResponder() -> Bool { if let surface { ghostty_surface_set_focus(surface, true) }; onFocus?(); return true }
    override func resignFirstResponder() -> Bool { if let surface { ghostty_surface_set_focus(surface, false) }; return true }
    private func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        for (flag, value): (NSEvent.ModifierFlags, UInt32) in [(.shift, 1), (.control, 2), (.option, 4), (.command, 8), (.capsLock, 16)] {
            if flags.contains(flag) { bits |= value }
        }
        return ghostty_input_mods_e(rawValue: bits)
    }
    private func key(_ event: NSEvent, action: ghostty_input_action_e, text: String?, composing: Bool = false) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action; key.keycode = UInt32(event.keyCode); key.mods = mods(event.modifierFlags)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        key.composing = composing
        if let text, !text.isEmpty, text.unicodeScalars.first!.value >= 0x20 {
            text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
        } else { _ = ghostty_surface_key(surface, key) }
    }
    // Match Discobox's paneKeymap: harnesses may disable extended keyboard
    // protocols, leaving modified Return indistinguishable from submission.
    private func enterChord(_ event: NSEvent) -> String? {
        guard event.keyCode == 36 || event.keyCode == 76 else { return nil }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers == .shift { return "text:\\x1b\\r" }
        if modifiers == .control { return "text:\\n" }
        return nil
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let sequence = enterChord(event) {
            binding(sequence)
            return
        }
        let wasMarked = hasMarkedText()
        inputText = []
        interpretKeyEvents([event])
        let text = inputText ?? []; inputText = nil
        if text.isEmpty {
            key(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                text: event.characters, composing: wasMarked || hasMarkedText())
        } else {
            for value in text { key(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: value) }
        }
    }
    override func keyUp(with event: NSEvent) {
        if enterChord(event) != nil { return }
        key(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "c": binding("copy_to_clipboard"); return true
            case "v": binding("paste_from_clipboard"); return true
            case "a": binding("select_all"); return true
            default: return false
            }
        }
        if event.modifierFlags.contains(.control) { keyDown(with: event); return true }
        return false
    }
    func sendLiteral(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
    private func binding(_ name: String) { if let surface { name.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count)) } } }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouse(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS) }
    override func mouseUp(with event: NSEvent) { mouse(event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_PRESS) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_RELEASE) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }; let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, p.y, mods(event.modifierFlags))
    }
    private func mouse(_ event: NSEvent, button: ghostty_input_mouse_button_e, state: ghostty_input_mouse_state_e) {
        mouseMoved(with: event); if let surface { _ = ghostty_surface_mouse_button(surface, state, button, mods(event.modifierFlags)) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    override func scrollWheel(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        unmarkText()
        if inputText != nil { inputText!.append(text) }
        else if let surface { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedSelection = selectedRange
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        if let surface { marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) } }
    }
    func unmarkText() { marked = NSAttributedString(string: ""); if let surface { ghostty_surface_preedit(surface, nil, 0) } }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let surface { ghostty_surface_ime_point(surface, &x, &y, &w, &h) }
        return window?.convertToScreen(convert(NSRect(x: x, y: y, width: w, height: h), to: nil)) ?? .zero
    }
    override func doCommand(by selector: Selector) {} // Ghostty encodes control/navigation keys.
}
