import SwiftUI
import DiscoboxCore

/// Uses the same retained forwards as Services; never opens an unforwarded
/// localhost URL which might belong to a different box or another computer.
struct WorkspaceDesktopButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(ServiceForwards.self) private var forwards
    @Environment(DesktopWindows.self) private var desktops
    @State private var opening = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        Button(action: open) {
            Label(opening ? "Opening…" : "Desktop", systemImage: "desktopcomputer")
                .labelStyle(.titleAndIcon)
        }.buttonStyle(.borderless).frame(width: 83)
            .disabled(workspace.selectedBox?.isRunning != true || workspace.isDemo || opening)
            .help("Open this box’s desktop in its own window")
            .accessibilityIdentifier("workspace.desktop")
            .onDisappear { task?.cancel(); opening = false }
    }
    private func open() {
        guard let box = workspace.selectedBox, box.isRunning, !opening, !workspace.isDemo else { return }
        let generation = workspace.connectionID
        let session = forwards.session(box: box.id, workspace: workspace)
        opening = true
        task = Task {
            defer { opening = false }
            for _ in 0..<100 {
                guard session.loading else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, workspace.connectionID == generation, workspace.sandboxID == box.id else { return }
            guard let port = session.ports.first(where: \.isDesktop), let url = port.browserURL else {
                workspace.commandError = session.error ?? "No Desktop service is available for this box. Open Services to check its available ports."
                return
            }
            desktops.open(url: url, box: box)
        }
    }
}
