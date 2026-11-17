#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Uses the same WindowGroups/openWindow actions as production. No live
/// terminals, desktops, credentials, or saved connections are accessed.
@MainActor enum NativeWindowSmoke {
    static func run() async {
        do {
            try await StudioModalSmoke.verify()
            var closed = 0
            let first = AuxiliaryWindow(kind: .desktop, title: "Fixture desktop A") { closed += 1 }
            first.content = AnyView(Text("Offline desktop fixture").frame(minWidth: 750, minHeight: 500))
            first.show()
            try await wait { first.window?.isVisible == true }
            let original = first.window!
            first.show()
            try await Task.sleep(for: .milliseconds(100))
            guard first.window === original, AuxiliaryWindows.shared.entries.count == 1 else {
                throw DiscoboxError("Reopening an auxiliary scene duplicated its window")
            }
            let second = AuxiliaryWindow(kind: .harness, title: "Fixture harness B") { closed += 1 }
            second.content = AnyView(Text("Offline harness fixture").frame(minWidth: 620, minHeight: 560))
            second.show()
            try await wait { second.window?.isVisible == true }
            first.requestClose()
            try await wait { first.closed }
            guard closed == 1, !second.closed, second.window?.isVisible == true else {
                throw DiscoboxError("Closing a scene affected another owner or missed cleanup")
            }
            first.close()
            guard closed == 1 else { throw DiscoboxError("Window resources released twice") }
            second.close()
            try await wait { second.window?.isVisible != true }
            guard closed == 2 else { throw DiscoboxError("Owner invalidation missed window cleanup") }

            let console = AuxiliaryWindow(kind: .console, title: "Fixture console") { closed += 1 }
            console.content = AnyView(Text("Unsaved fixture editor").frame(minWidth: 640, minHeight: 400))
            console.needsCloseConfirmation = { true }
            console.show()
            try await wait { console.window?.isVisible == true }
            console.requestClose()
            try await answer(console, title: "Cancel")
            guard !console.closed, closed == 2, NSApp.modalWindow == nil else {
                throw DiscoboxError("Cancelling console close lost resources or blocked the app")
            }
            console.requestClose()
            try await answer(console, title: "Close Console")
            try await wait { console.closed }
            guard closed == 3 else { throw DiscoboxError("Confirmed close missed console cleanup") }

            let invalidated = AuxiliaryWindow(kind: .console, title: "Fixture invalidated console") { closed += 1 }
            invalidated.content = AnyView(Text("Disconnected fixture").frame(minWidth: 640, minHeight: 400))
            invalidated.needsCloseConfirmation = { true }
            invalidated.show()
            try await wait { invalidated.window?.isVisible == true }
            invalidated.requestClose()
            try await wait { invalidated.window?.attachedSheet != nil }
            invalidated.close()
            try await wait { invalidated.window?.isVisible != true }
            guard invalidated.window?.attachedSheet == nil, closed == 4 else {
                throw DiscoboxError("Disconnect prompted for obsolete console edits")
            }
            let pending = AuxiliaryWindow(kind: .harness, title: "Fixture pending scene") { closed += 1 }
            pending.content = AnyView(Text("Pending fixture"))
            pending.show(); pending.close()
            try await Task.sleep(for: .milliseconds(250))
            guard closed == 5, AuxiliaryWindows.shared.entries.isEmpty else {
                throw DiscoboxError("An invalidated pending scene resurrected its resources")
            }
            print("NATIVE_WINDOW_SMOKE_OK: scene reuse, independent owners, user close, cancelled/confirmed console close, disconnect and pending-window cleanup; no app-modal loop")
            fflush(stdout); exit(0)
        } catch { print("NATIVE_WINDOW_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw DiscoboxError("Native scene did not settle at line \(line); entries=\(AuxiliaryWindows.shared.entries.values.map { $0.title + ": " + String(describing: $0.window) })")
    }
    private static func answer(_ entry: AuxiliaryWindow, title: String) async throws {
        try await wait { entry.window?.attachedSheet != nil }
        guard let sheet = entry.window?.attachedSheet, let root = sheet.contentView,
              let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            throw DiscoboxError("Missing native confirmation button: " + title)
        }
        button.performClick(nil)
        try await wait { entry.window?.attachedSheet == nil }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
