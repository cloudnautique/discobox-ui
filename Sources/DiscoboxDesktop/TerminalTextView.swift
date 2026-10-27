import AppKit
import SwiftUI

/// Displays the backend's rendered screen, not raw ANSI. AppKit gives us native
/// selection, accessibility, copy, and horizontal scrolling without a WebView.
struct TerminalTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("Terminal screen, read only")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let follow = view.string.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 32
        let origin = scroll.contentView.bounds.origin
        let selection = view.selectedRange()
        view.string = text
        if NSMaxRange(selection) <= (text as NSString).length { view.setSelectedRange(selection) }
        if follow { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}
