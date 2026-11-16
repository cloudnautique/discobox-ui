import SwiftUI
import AppKit
import DiscoboxCore

/// Trackpad overscroll at the top of this list only. Events continue to the
/// native scroll view; terminal and inspector scrolling are never intercepted.
struct BoxPullToRefresh: NSViewRepresentable {
    let refresh: @MainActor () async -> Void
    func makeNSView(context: Context) -> PullView { PullView(refresh: refresh) }
    func updateNSView(_ view: PullView, context: Context) { view.refresh = refresh }
    static func dismantleNSView(_ view: PullView, coordinator: ()) { view.stop() }
    @MainActor final class PullView: NSView {
        var refresh: @MainActor () async -> Void
        private var monitor: Any?
        private var gesture = BoxRefreshGesture()
        private var refreshing = false
        init(refresh: @escaping @MainActor () async -> Void) { self.refresh = refresh; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scroll(event) }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        private func scroll(_ event: NSEvent) {
            guard let window, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)), event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { gesture.reset() }
            if !event.phase.intersection([.ended, .cancelled]).isEmpty { gesture.reset(); return }
            guard !refreshing, event.hasPreciseScrollingDeltas,
                  let hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil)),
                  let scroll = hit.enclosingScrollView, let document = scroll.documentView else { return }
            let atTop = document.isFlipped ? scroll.documentVisibleRect.minY <= 1 : scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1
            if gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, atTop: atTop) {
                refreshing = true
                Task { await refresh(); refreshing = false }
            }
        }
    }
}
