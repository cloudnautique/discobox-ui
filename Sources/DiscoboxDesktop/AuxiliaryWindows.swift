import SwiftUI
import AppKit

/// SwiftUI owns the windows. This registry owns only the live resources shown
/// in them; opaque scene IDs cannot restore an old connection or credential.
@MainActor @Observable final class AuxiliaryWindow: Identifiable {
    enum Kind: String { case desktop, harness, console }
    let id = UUID()
    let kind: Kind
    let title: String
    var content: AnyView?
    weak var window: NSWindow?
    var needsCloseConfirmation: () -> Bool = { false }
    private(set) var closed = false
    private var cleanup: (() -> Void)?

    init(kind: Kind, title: String, cleanup: @escaping () -> Void) {
        self.kind = kind; self.title = title; self.cleanup = cleanup
    }
    func onClose(_ action: @escaping () -> Void) { cleanup = action }
    func show() { AuxiliaryWindows.shared.present(self) }
    /// Owner invalidation bypasses the user-close prompt and releases resources
    /// even if the scene has not mounted yet.
    func close() {
        guard !closed else { return }
        // A host can disappear while its close/review sheet is open. End that
        // sheet first; otherwise AppKit can refuse the scene dismissal.
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        finish()
        DispatchQueue.main.async { [self] in AuxiliaryWindows.shared.dismiss(self) }
    }
    func requestClose() { window?.performClose(nil) }
    func finish() {
        guard !closed else { return }
        closed = true
        let action = cleanup; cleanup = nil
        content = nil
        AuxiliaryWindows.shared.remove(id)
        action?()
    }
}

@MainActor @Observable final class AuxiliaryWindows {
    static let shared = AuxiliaryWindows()
    private(set) var entries: [UUID: AuxiliaryWindow] = [:]
    private var open: OpenWindowAction?
    private var dismissAction: DismissWindowAction?

    func install(open: OpenWindowAction, dismiss: DismissWindowAction) {
        self.open = open; self.dismissAction = dismiss
    }
    func present(_ entry: AuxiliaryWindow) {
        guard !entry.closed else { return }
        entries[entry.id] = entry
        open?(id: entry.kind.rawValue, value: entry.id)
    }
    func dismiss(_ entry: AuxiliaryWindow) {
        dismissAction?(id: entry.kind.rawValue, value: entry.id)
    }
    func remove(_ id: UUID) { entries.removeValue(forKey: id) }
}

struct AuxiliaryWindowActions: ViewModifier {
    @Environment(\.openWindow) private var open
    @Environment(\.dismissWindow) private var dismiss
    func body(content: Content) -> some View {
        content.onAppear { AuxiliaryWindows.shared.install(open: open, dismiss: dismiss) }
    }
}

struct AuxiliaryWindowScenes: Scene {
    var body: some Scene {
        WindowGroup("Desktop", id: AuxiliaryWindow.Kind.desktop.rawValue, for: UUID.self) { $id in
            AuxiliaryWindowHost(id: id)
        }.defaultSize(width: 1150, height: 800).windowResizability(.contentMinSize).commandsRemoved()
        WindowGroup("Shared login and settings", id: AuxiliaryWindow.Kind.harness.rawValue, for: UUID.self) { $id in
            AuxiliaryWindowHost(id: id)
        }.defaultSize(width: 720, height: 640).windowResizability(.contentMinSize).commandsRemoved()
        WindowGroup("Manage Harnesses", id: AuxiliaryWindow.Kind.console.rawValue, for: UUID.self) { $id in
            AuxiliaryWindowHost(id: id)
        }.defaultSize(width: 900, height: 620).windowResizability(.contentMinSize).commandsRemoved()
    }
}

private struct AuxiliaryWindowHost: View {
    let id: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let id, let entry = AuxiliaryWindows.shared.entries[id], !entry.closed {
                entry.content
                    .navigationTitle(entry.title)
                    .background(AuxiliaryWindowLifecycle(entry: entry))
            } else {
                // Scene restoration may supply an ID from an earlier launch.
                // It must never resurrect a terminal or remote connection.
                Color.clear.task { dismiss() }
            }
        }.modifier(AuxiliaryWindowActions())
    }
}

/// A small AppKit bridge for close notifications and the legacy console's
/// asynchronous close veto. Preserve SwiftUI's window delegate and forward all
/// other methods to it; never start a nested application-modal event loop.
private struct AuxiliaryWindowLifecycle: NSViewRepresentable {
    let entry: AuxiliaryWindow
    func makeNSView(context: Context) -> Probe { Probe(entry: entry) }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        let entry: AuxiliaryWindow
        private var observer: NSObjectProtocol?
        private var closeDelegate: CloseDelegate?
        private weak var observedWindow: NSWindow?
        init(entry: AuxiliaryWindow) { self.entry = entry; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { detach(); return }
            guard observedWindow !== window else { return }
            detach()
            observedWindow = window
            entry.window = window
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak entry] _ in
                MainActor.assumeIsolated { entry?.finish() }
            }
            if entry.kind == .console {
                let delegate = CloseDelegate(entry: entry, previous: window.delegate)
                closeDelegate = delegate
                window.delegate = delegate
            }
        }
        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let closeDelegate, observedWindow?.delegate === closeDelegate {
                observedWindow?.delegate = closeDelegate.previous
            }
            closeDelegate = nil; observedWindow = nil
        }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        let entry: AuxiliaryWindow
        weak var previous: (any NSWindowDelegate)?
        private var confirming = false
        init(entry: AuxiliaryWindow, previous: (any NSWindowDelegate)?) { self.entry = entry; self.previous = previous }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !entry.closed, entry.needsCloseConfirmation() else {
                return previous?.windowShouldClose?(sender) ?? true
            }
            guard !confirming, sender.attachedSheet == nil else { return false }
            confirming = true
            StudioAppKitDialog.confirm(title: "Close harness management?", symbol: "terminal",
                message: "This closes the harness console. Unsaved changes in its current editor may be lost.",
                confirmTitle: "Close Console", destructive: true, defaultConfirm: false, for: sender) { [weak self] accepted in
                    guard let self else { return }
                    self.confirming = false
                    guard accepted, !self.entry.closed else { return }
                    // NSAlert finishes its sheet before the next main-loop
                    // turn. Re-entering performClose during that completion
                    // can be ignored by AppKit while the sheet is ending.
                    DispatchQueue.main.async { [entry = self.entry] in entry.close() }
                }
            return false
        }
    }
}
