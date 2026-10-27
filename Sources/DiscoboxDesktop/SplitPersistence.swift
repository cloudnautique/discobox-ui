import AppKit
import SwiftUI

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
