#if DEBUG
@testable import DiscoboxUI
import AppKit
import GhosttyKit
import DiscoboxCore

/// Exercise the actual embedded URL matcher and click callback, without opening
/// a browser, contacting a server, or changing a working terminal session.
@MainActor enum BoxLinkSmoke {
    static func run() async {
        let view = GhosttyTerminalView(frame: .init(x: 0, y: 0, width: 900, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        var opened: [String] = []
        view.openURL = { opened.append($0); return true }
        do {
            let relative = "discobox:///sbx_fixture"
            let qualified = "discobox+https://fixture.example/sbx_fixture"
            let fixture = "Box links\r\n\r\nResearch (\(relative)).\r\nRemote \(qualified)\r\n\u{1b}]8;;\(relative)\u{7}Desktop demo\u{1b}]8;;\u{7}\r\n"
            let script = "/usr/bin/printf %s " + TerminalSession.quote(fixture) + "; /bin/sleep 30"
            if let failure = view.start(command: "/bin/sh -c " + TerminalSession.quote(script)) { throw DiscoboxError(failure) }
            defer { view.close(); window.orderOut(nil) }
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<100 {
                if text(view).contains("Desktop demo") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard text(view).contains(qualified), let surface = view.surface else { throw DiscoboxError("Box-link terminal fixture did not render") }
            let size = ghostty_surface_size(surface)
            let scale = window.backingScaleFactor
            // Locate rows rather than assuming a fixed origin: macOS login
            // may prepend a last-login banner before the synthetic command.
            let lines = text(view).components(separatedBy: "\n")
            for (label, expected) in [("Research (", relative), ("Remote ", qualified), ("Desktop demo", relative)] {
                guard let row = lines.firstIndex(where: { $0.contains(label) }), let range = lines[row].range(of: label) else {
                    throw DiscoboxError("Missing rendered link fixture")
                }
                let column = lines[row].distance(from: lines[row].startIndex, to: range.lowerBound) + (label == "Desktop demo" ? 4 : label.count + 4)
                let count = opened.count
                ghostty_surface_mouse_pos(surface, (Double(column) + 0.5) * Double(size.cell_width_px) / scale,
                    (Double(row) + 0.5) * Double(size.cell_height_px) / scale, ghostty_input_mods_e(rawValue: 8))
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghostty_input_mods_e(rawValue: 8))
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghostty_input_mods_e(rawValue: 8))
                for _ in 0..<100 { if opened.count > count { break }; try await Task.sleep(for: .milliseconds(20)) }
                guard opened.count == count + 1, opened.last == expected else {
                    throw DiscoboxError("URL click at row \(row) did not deliver its complete Discobox address: \(opened)")
                }
            }
            print("BOX_LINK_SMOKE_OK: plain relative and qualified URLs, surrounding punctuation and OSC 8 labels reach the native callback exactly once; no browser or server opened")
            fflush(stdout); exit(0)
        } catch {
            view.close(); window.orderOut(nil)
            print("BOX_LINK_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1)
        }
    }

    private static func text(_ view: GhosttyTerminalView) -> String {
        guard let surface = view.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return "" }
        defer { ghostty_surface_free_text(surface, &result) }
        return result.text.map { String(cString: $0) } ?? ""
    }
}

#endif
