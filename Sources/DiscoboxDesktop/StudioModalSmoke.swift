import AppKit
import SwiftUI
import DiscoboxCore

/// Real AppKit modal/sheet lifetimes, without accessing the clipboard or server.
@MainActor enum StudioModalSmoke {
    static func verify() async throws {
        for (defaultConfirm, useDefault) in [(true, true), (false, true), (true, false), (false, false)] {
            let probe = Probe()
            let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
                MainActor.assumeIsolated {
                    probe.ticks += 1
                    if probe.ticks > 100 {
                        probe.timer?.invalidate(); probe.timedOut = true; NSApp.stopModal(withCode: .cancel); return
                    }
                    guard let panel = NSApp.modalWindow, let root = panel.contentView else { return }
                    root.layoutSubtreeIfNeeded()
                    let buttons = views(root).compactMap { $0 as? NSButton }
                    let button = useDefault ? buttons.first { $0.cell === panel.defaultButtonCell } :
                        buttons.first { $0.cell !== panel.defaultButtonCell }
                    if let button, button.isEnabled {
                        probe.validSize = panel.frame.width >= 550 && panel.frame.height > 150
                        probe.timer?.invalidate(); button.performClick(nil)
                    }
                }
            }
            probe.timer = timer
            RunLoop.main.add(timer, forMode: .modalPanel)
            let accepted = StudioAppKitDialog.confirm(title: "Fixture confirmation", symbol: "doc.on.clipboard",
                message: "Offline fixture. No clipboard or credential access.", confirmTitle: "Allow", defaultConfirm: defaultConfirm)
            timer.invalidate()
            probe.timer = nil
            guard !probe.timedOut, probe.validSize, accepted == (useDefault ? defaultConfirm : !defaultConfirm) else {
                throw DiscoboxError("Studio AppKit modal changed the default choice, response or sizing")
            }
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Color.clear)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        StudioAppKitDialog.message(title: "Fixture connection error", symbol: "network.slash", message: "No network access was performed.", for: window)
        for _ in 0..<100 {
            if let sheet = window.attachedSheet, let root = sheet.contentView,
               let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.cell === sheet.defaultButtonCell }) {
                button.performClick(nil)
                for _ in 0..<100 {
                    if window.attachedSheet == nil {
                        print("STUDIO_APPKIT_MODAL_SMOKE_OK: confirmation responses/defaults preserved, native callback panels fit, informational sheet dismisses; no clipboard or backend access")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DiscoboxError("Studio AppKit informational sheet did not dismiss")
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    @MainActor private final class Probe {
        var ticks = 0
        var validSize = false
        var timedOut = false
        var timer: Timer?
    }
}
