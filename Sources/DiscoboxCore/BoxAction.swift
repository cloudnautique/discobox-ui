import Foundation

public enum BoxAction: String, CaseIterable, Identifiable, Sendable {
    case start, stop, archive, unarchive, upgrade, repair, purge, rename
    public var id: Self { self }
    public var title: String { self == .unarchive ? "Restore" : rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .start: "play"
        case .stop: "stop"
        case .archive: "archivebox"
        case .unarchive: "arrow.uturn.backward"
        case .upgrade: "arrow.up.circle"
        case .repair: "wrench.and.screwdriver"
        case .purge: "trash"
        case .rename: "pencil"
        }
    }
    public var explanation: String {
        switch self {
        case .start: "Start this box and its harness."
        case .stop: "Stop this box and its running processes. Workspace data is kept."
        case .archive: "Remove the container and keep its workspace data. You can restore the box from Archived. Running processes will end."
        case .unarchive: "Recreate the container using its retained data. The restored box is left stopped."
        case .upgrade: "Rebuild on the harness’s current image. Workspace data, sources, caches, and secrets are kept. Running processes end; packages and files elsewhere in the container are lost."
        case .repair: "Rebuild and start this box on the harness’s current image. Workspace data and uncommitted changes survive. Running processes and disposable container state are replaced."
        case .purge: "Permanently delete this box, its workspace, configuration, and secrets. This cannot be undone."
        case .rename: "Set a name for this box. Renaming a stopped box starts it so the name can be written into its workspace."
        }
    }
    public func isAvailable(for box: Sandbox) -> Bool {
        let state = box.runtime.displayState ?? box.runtime.state
        if ["deleted", "deleting", "archiving", "repairing", "starting", "stopping"].contains(state) { return false }
        if box.isArchived { return self == .unarchive || self == .purge }
        switch self {
        case .unarchive, .purge: return false
        case .start: return !box.isRunning && box.runtime.state == "ready"
        case .stop: return box.isRunning
        default: return true
        }
    }
}
