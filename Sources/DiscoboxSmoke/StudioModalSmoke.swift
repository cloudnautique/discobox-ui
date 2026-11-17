#if DEBUG
@testable import DiscoboxUI
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
        guard try await answerSheet(on: window, useDefault: true) else {
            throw DiscoboxError("Studio AppKit informational sheet did not dismiss")
        }
        // Terminal clipboard callbacks: the call returns before the answer,
        // presents on the terminal's window, and reports each button once.
        for useDefault in [true, false] {
            let answer = Answer()
            StudioAppKitDialog.confirm(title: "Fixture clipboard request", symbol: "doc.on.clipboard",
                message: "Offline fixture. No clipboard access.", confirmTitle: "Allow", for: window) { answer.values.append($0) }
            guard answer.values.isEmpty, try await answerSheet(on: window, useDefault: useDefault) else {
                throw DiscoboxError("Studio window-attached confirmation blocked its caller or did not dismiss")
            }
            guard answer.values == [useDefault] else {
                throw DiscoboxError("Studio window-attached confirmation reported the wrong response")
            }
        }
        let windowless = Answer()
        StudioAppKitDialog.confirm(title: "Fixture clipboard request", symbol: "doc.on.clipboard",
            message: "Offline fixture.", confirmTitle: "Allow", for: nil) { windowless.values.append($0) }
        guard windowless.values == [false], NSApp.modalWindow == nil else {
            throw DiscoboxError("Studio confirmation without a window was not declined")
        }
        print("STUDIO_APPKIT_MODAL_SMOKE_OK: confirmation responses/defaults preserved, native callback panels fit, informational and window-attached confirmation sheets dismiss without blocking; no clipboard or backend access")
    }
    /// Clicks the sheet's default (or other) button; true once it has dismissed.
    private static func answerSheet(on window: NSWindow, useDefault: Bool) async throws -> Bool {
        for _ in 0..<100 {
            if let sheet = window.attachedSheet, let root = sheet.contentView {
                root.layoutSubtreeIfNeeded()
                let buttons = views(root).compactMap { $0 as? NSButton }
                if let button = useDefault ? buttons.first(where: { $0.cell === sheet.defaultButtonCell })
                                           : buttons.first(where: { $0.cell !== sheet.defaultButtonCell }) {
                    button.performClick(nil)
                    for _ in 0..<100 {
                        if window.attachedSheet == nil { return true }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    return false
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    @MainActor private final class Answer { var values: [Bool] = [] }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    @MainActor private final class Probe {
        var ticks = 0
        var validSize = false
        var timedOut = false
        var timer: Timer?
    }
}

#endif
