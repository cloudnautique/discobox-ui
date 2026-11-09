import AppKit
import SwiftUI
import DiscoboxCore

/// Let NSSplitView preserve the user's divider positions rather than imposing
/// SwiftUI fractions each time the box reappears.
struct SplitPersistence: NSViewRepresentable {
    let name: String?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.name = name
        DispatchQueue.main.async { view.configure() }
    }
    final class Probe: NSView {
        var name: String?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let name else { return }
            var parent = superview
            while let view = parent {
                if let split = view as? NSSplitView {
                    if split.autosaveName != name { split.autosaveName = name }
                    return
                }
                parent = view.superview
            }
        }
    }
}

/// Apply an initial proportion only when a detail pane is first inserted.
/// Subsequent layout passes leave the user's divider position alone.
struct InitialSplitFraction: NSViewRepresentable {
    let fraction: CGFloat
    func makeNSView(context: Context) -> Probe { Probe(fraction: fraction) }
    func updateNSView(_ view: Probe, context: Context) { view.schedule() }
    final class Probe: NSView {
        let fraction: CGFloat
        private var applied = false
        init(fraction: CGFloat) { self.fraction = fraction; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard !applied else { return }
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        private func configure() {
            guard !applied, window != nil else { return }
            var parent = superview
            while let view = parent {
                if let split = view as? NSSplitView {
                    guard split.arrangedSubviews.count == 2, split.bounds.height > 0 else { return }
                    applied = true
                    split.setPosition((split.bounds.height - split.dividerThickness) * fraction, ofDividerAt: 0)
                    return
                }
                parent = view.superview
            }
        }
    }
}

/// Restore after SwiftUI has attached and sized both children. A toolbar click
/// must not be recorded as a divider drag or overwrite the preferred fraction.
struct WorkspaceSplitPosition: NSViewRepresentable {
    let key: String
    let enabled: Bool
    var fraction: CGFloat = 0.55
    var minimum: CGFloat = 360
    var secondaryMinimum: CGFloat = 360
    var revision = ""
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.key = key; view.enabled = enabled
        view.initialFraction = fraction; view.minimum = minimum; view.secondaryMinimum = secondaryMinimum
        view.revision = revision
        view.schedule()
    }
    final class Probe: NSView {
        var key = ""
        var enabled = false
        var initialFraction: CGFloat = 0.55
        var minimum: CGFloat = 360 { didSet { if oldValue != minimum { configuredKey = nil } } }
        var secondaryMinimum: CGFloat = 360 { didSet { if oldValue != secondaryMinimum { configuredKey = nil } } }
        var revision = "" { didSet { if oldValue != revision { configuredKey = nil } } }
        private weak var split: NSSplitView?
        private var preferenceKey: String?
        private var configuredKey: String?
        private var observer: NSObjectProtocol?
        private var mouseMonitor: Any?
        private var saveTask: Task<Void, Never>?
        private var restoreTask: Task<Void, Never>?
        private var restoring = false
        private var dividerDrag = false
        private var preferredFraction: Double = 0.55
        private var lastLength: CGFloat = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                saveTask?.cancel(); restoreTask?.cancel()
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
                split = nil; configuredKey = nil
            } else { schedule() }
        }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            if !enabled {
                configuredKey = nil; saveTask?.cancel(); restoreTask?.cancel(); dividerDrag = false
                return
            }
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        private func configure() {
            guard enabled, window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let candidate = view as? NSSplitView {
                    guard candidate.arrangedSubviews.count == 2 else { return }
                    if split !== candidate {
                        if let observer { NotificationCenter.default.removeObserver(observer) }
                        split = candidate; configuredKey = nil
                        observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: candidate, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.resized() }
                        }
                    }
                    if mouseMonitor == nil {
                        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                            MainActor.assumeIsolated { self?.mouse(event) }
                            return event
                        }
                    }
                    guard configuredKey != key else { return }
                    configuredKey = key
                    if preferenceKey != key {
                        preferenceKey = key
                        preferredFraction = UserDefaults.standard.object(forKey: "paneFraction." + key) as? Double ?? Double(initialFraction)
                    }
                    lastLength = length(candidate)
                    deferRestore()
                    return
                }
                ancestor = view.superview
            }
        }
        private func length(_ split: NSSplitView) -> CGFloat {
            (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        }
        private func deferRestore() {
            restoreTask?.cancel()
            let expectedKey = key
            restoreTask = Task { [weak self] in
                // Conditional panes get a provisional minimum-sized frame in
                // their first layout. Wait for that insertion to settle first.
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, self.enabled, self.key == expectedKey, !self.dividerDrag,
                      let split = self.split, split.window != nil, split.arrangedSubviews.count == 2 else { return }
                let length = self.length(split)
                guard length > 0 else { return }
                self.lastLength = length
                let value = WorkspaceSizing.fraction(preferred: self.preferredFraction, length: length, minimum: self.minimum, secondaryMinimum: self.secondaryMinimum)
                self.restoring = true
                split.setPosition(length * value, ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
                self.restoring = false
            }
        }
        private func mouse(_ event: NSEvent) {
            guard enabled else { return }
            if event.type == .leftMouseUp { dividerDrag = false; return }
            dividerDrag = false
            guard let split, event.window === split.window, split.arrangedSubviews.count == 2 else { return }
            let first = split.arrangedSubviews[0].frame, second = split.arrangedSubviews[1].frame
            let rect = split.isVertical
                ? NSRect(x: min(first.maxX, second.maxX), y: split.bounds.minY, width: split.dividerThickness, height: split.bounds.height).insetBy(dx: -3, dy: 0)
                : NSRect(x: split.bounds.minX, y: min(first.maxY, second.maxY), width: split.bounds.width, height: split.dividerThickness).insetBy(dx: 0, dy: -3)
            dividerDrag = rect.contains(split.convert(event.locationInWindow, from: nil))
            if dividerDrag { restoreTask?.cancel() }
        }
        private func resized() {
            guard enabled, !restoring, configuredKey == key, window != nil,
                  let split, split.arrangedSubviews.count == 2 else { return }
            let length = length(split)
            if abs(length - lastLength) > 1 {
                lastLength = length
                if !dividerDrag { deferRestore() }
            }
            guard dividerDrag, NSEvent.pressedMouseButtons != 0, window?.inLiveResize != true, length > 0 else { return }
            let first = split.arrangedSubviews[0]
            let size = split.isVertical ? first.frame.width : first.frame.height
            guard size > 100, length - size > 100 else { return }
            preferredFraction = Double(size / length)
            let value = preferredFraction, savedKey = key
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, self.enabled, self.key == savedKey else { return }
                UserDefaults.standard.set(value, forKey: "paneFraction." + savedKey)
            }
        }
    }
}
