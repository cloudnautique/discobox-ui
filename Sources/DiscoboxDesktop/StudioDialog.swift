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
    var destructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(destructive ? Color.red : DiscoboxAppearance.accent)
                .frame(width: 36, height: 36)
                .background(destructive ? Color.red.opacity(0.1) : DiscoboxAppearance.selection, in: RoundedRectangle(cornerRadius: 9))
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

/// Consistent Studio chrome for lifecycle and destructive confirmations.
/// Content and native buttons keep each flow's existing validation and actions.
struct StudioConfirmation<Content: View, Footer: View>: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var destructive = false
    var width: CGFloat = 560
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            StudioDialogHeader(title: title, symbol: symbol, subtitle: subtitle, destructive: destructive).padding(24)
            Divider().overlay(DiscoboxAppearance.border)
            content.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider().overlay(DiscoboxAppearance.border)
            footer.controlSize(.large).frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 16).background(DiscoboxAppearance.chrome)
        }.frame(width: width).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
    }
}

struct StudioConfirmationSubject: View {
    let name: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).padding(.top, 2)
            Text(name).font(.system(size: 13, weight: .semibold)).textSelection(.enabled).lineLimit(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
    }
}

struct StudioConfirmationField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content.textFieldStyle(.plain).font(.system(size: 13)).padding(10)
                .background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
        }
    }
}

struct StudioMessageSheet: View {
    let title: String
    let symbol: String
    let message: String
    var confirmTitle = "Done"
    var destructive = false
    var defaultConfirm = true
    var cancel: (() -> Void)? = nil
    let confirm: () -> Void

    var body: some View {
        StudioConfirmation(title: title, symbol: symbol, destructive: destructive) {
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } footer: {
            HStack {
                if let cancel {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(defaultConfirm ? .cancelAction : .defaultAction)
                }
                Spacer()
                Button(confirmTitle, role: destructive ? .destructive : nil, action: confirm)
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : DiscoboxAppearance.accent)
                    .keyboardShortcut(defaultConfirm ? .defaultAction : nil)
            }
        }.onExitCommand { (cancel ?? confirm)() }
    }
}

extension View {
    func studioCard() -> some View {
        self.background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
    }
}

/// Native determinate bars can lose their tint in inactive light windows.
/// Keep ProgressView's accessibility while painting the Studio quota colors.
struct StudioQuotaProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        let value = configuration.fractionCompleted ?? 0
        let fraction = value.isFinite ? min(1, max(0, value)) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DiscoboxAppearance.border)
                Capsule().fill(fraction >= 0.9 ? Color.orange : DiscoboxAppearance.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }.frame(height: 5)
    }
}

/// App-owned AppKit callbacks use the same SwiftUI chrome as other sheets.
/// Synchronous terminal callbacks retain their original modal lifetime.
@MainActor enum StudioAppKitDialog {
    static func confirm(title: String, symbol: String, message: String, confirmTitle: String,
                        destructive: Bool = false, defaultConfirm: Bool = true) -> Bool {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: StudioMessageSheet(title: title, symbol: symbol, message: message,
            confirmTitle: confirmTitle, destructive: destructive, defaultConfirm: defaultConfirm,
            cancel: { NSApp.stopModal(withCode: .cancel) }, confirm: { NSApp.stopModal(withCode: .OK) }))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.center()
        let accepted = NSApp.runModal(for: panel) == .OK
        panel.orderOut(nil); panel.contentView = nil
        return accepted
    }

    static func message(title: String, symbol: String, message: String, for window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: StudioMessageSheet(title: title, symbol: symbol, message: message) {
            window.endSheet(panel)
        })
        panel.setContentSize(panel.contentView!.fittingSize)
        window.beginSheet(panel) { _ in panel.orderOut(nil); panel.contentView = nil }
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
