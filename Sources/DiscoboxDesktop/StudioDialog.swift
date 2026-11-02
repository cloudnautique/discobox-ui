import SwiftUI
import AppKit
import DiscoboxCore

/// Shared chrome for compact Studio sheets. Native controls retain their
/// editing, accessibility, and keyboard behavior inside these surfaces.
struct StudioDialogHeader: View {
    let title: String
    let symbol: String
    var subtitle: String?
    var shortcut: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DiscoboxAppearance.accent)
                .frame(width: 36, height: 36)
                .background(DiscoboxAppearance.selection, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            if let shortcut, let binding = AppShortcut(shortcut) {
                StudioKeycap(text: (binding.control ? "⌃" : "") + (binding.option ? "⌥" : "") + (binding.shift ? "⇧" : "") + "⌘" + binding.key.uppercased())
            }
        }
    }
}

struct StudioKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 3)
            .background(DiscoboxAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
    }
}

struct StudioFieldLabel: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text("Optional").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct StudioDestinationRow<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            content.frame(maxWidth: 330, alignment: .trailing)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 43)
    }
}

/// A borderless native popup keeps the compact down-chevron presentation and
/// the same menu keyboard/accessibility behavior as the standard macOS picker.
struct StudioMenuPicker: View {
    struct Option: Equatable {
        let id: String
        let title: String
        var enabled = true
    }
    let title: String
    @Binding var selection: String
    let options: [Option]
    var alignment: NSTextAlignment = .right

    var body: some View {
        StudioNativeMenuPicker(title: title, selection: $selection, options: options)
            .frame(height: 22)
            .overlay {
                HStack(spacing: 8) {
                    Text(options.first { $0.id == selection }?.title ?? "")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: alignment == .left ? .leading : .trailing)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct StudioNativeMenuPicker: NSViewRepresentable {
    typealias Option = StudioMenuPicker.Option
    let title: String
    @Binding var selection: String
    let options: [Option]

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = Popup(frame: .zero, pullsDown: false)
        button.isBordered = false
        // SwiftUI draws the label and one chevron over this complete native
        // hit target. The popup still owns the menu, selection and accessibility.
        button.font = .systemFont(ofSize: 12)
        button.menu?.autoenablesItems = false
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    private final class Popup: NSPopUpButton {
        // Modern popup cells ignore NSButton.isTransparent/arrowPosition.
        // Only the hosting overlay paints chrome; the native menu remains.
        override func draw(_ dirtyRect: NSRect) {}
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.options != options {
            button.removeAllItems()
            for option in options {
                let item = NSMenuItem(title: option.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.representedObject = option.id
                item.isEnabled = option.enabled
                item.target = context.coordinator
                button.menu?.addItem(item)
            }
            context.coordinator.options = options
        }
        button.selectItem(at: options.firstIndex { $0.id == selection } ?? -1)
        button.isEnabled = context.environment.isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var parent: StudioNativeMenuPicker
        var options: [Option] = []
        init(_ parent: StudioNativeMenuPicker) { self.parent = parent }
        @objc func choose(_ item: NSMenuItem) {
            guard item.isEnabled, let id = item.representedObject as? String else { return }
            parent.selection = id
        }
    }
}
