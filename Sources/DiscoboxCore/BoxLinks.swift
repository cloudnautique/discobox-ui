import Foundation

public struct BoxLinkTarget: Sendable, Equatable {
    public let location: BoxLocation
    public let generation: UUID
}

public enum BoxLinks {
    public static func claims(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        return ["discobox", "discobox+http", "discobox+https"].contains(raw[..<colon].lowercased())
    }
}

public extension Connections {
    /// The reader is the originating terminal's computer, not whichever
    /// computer happens to be active after an asynchronous lookup completes.
    /// Parsing and identity reads never register or connect to a new server.
    func resolveBoxLink(_ raw: String, readerID: String, generation: UUID) async throws -> BoxLinkTarget {
        guard let reader = session(readerID), reader.workspace.isConnected,
              reader.workspace.connectionID == generation else {
            throw DiscoboxError("Connect to the computer that supplied this box link first.")
        }
        let connected = sessions.filter { $0.workspace.isConnected }
        let generations = Dictionary(uniqueKeysWithValues: connected.map { ($0.id, $0.workspace.connectionID) })
        let parsed = try await reader.workspace.operation(.boxLink, link: raw,
            payload: .array(connected.map { .string($0.profile.endpoint) }))
        try Task.checkCancellation()
        guard reader.workspace.connectionID == generation, reader.workspace.isConnected else { throw CancellationError() }
        let boxID = parsed["sandbox"].string
        guard !boxID.isEmpty else { throw DiscoboxError("This link does not name a box.") }
        let candidates: [ConnectionSession]
        if parsed["local"] == .bool(true) {
            candidates = [reader]
        } else {
            let matched = Set(parsed["matches"].array.map(\.string))
            var hosts = connected.filter { matched.contains($0.profile.endpoint) }
            if hosts.isEmpty, !parsed["peerID"].string.isEmpty {
                let peer = parsed["peerID"].string
                // Query only already-connected servers, concurrently. A click
                // is not permission to dial an address written by a program.
                let ids = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for host in connected {
                        let workspace = host.workspace, id = host.id
                        group.addTask {
                            let value = try? await workspace.operation(.serverPeer)
                            return value?["peerId"].string == peer ? id : nil
                        }
                    }
                    var ids: [String] = []
                    for await id in group { if let id { ids.append(id) } }
                    return ids
                }
                hosts = connected.filter { ids.contains($0.id) }
            }
            candidates = hosts
        }
        try Task.checkCancellation()
        guard reader.workspace.connectionID == generation, reader.workspace.isConnected else { throw CancellationError() }
        guard !candidates.isEmpty else {
            throw DiscoboxError("This box link names a computer that is not connected. Add or connect to it in Settings → Connections, then open the link again.")
        }
        guard candidates.count == 1, let host = candidates.first else {
            throw DiscoboxError("More than one connected computer matches this link. Disconnect the duplicate connection and try again.")
        }
        let targetGeneration = generations[host.id]
        func valid() -> Bool {
            reader.workspace.isConnected && reader.workspace.connectionID == generation &&
                host.workspace.isConnected && host.workspace.connectionID == targetGeneration
        }
        guard valid() else { throw CancellationError() }
        // A worker may have just created the linked box. Give inventory one
        // fresh read if needed, without creating or starting anything.
        if !host.workspace.sandboxes.contains(where: { $0.id == boxID || $0.id.hasPrefix(boxID) }) {
            await host.workspace.refresh()
        }
        try Task.checkCancellation()
        guard valid() else { throw CancellationError() }
        let boxes = host.workspace.sandboxes.filter { !$0.isDeleted }
        let exact = boxes.first { $0.id == boxID }
        let matches = exact.map { [$0] } ?? boxes.filter { $0.id.hasPrefix(boxID) }
        guard matches.count == 1, let box = matches.first else {
            throw DiscoboxError(matches.isEmpty
                ? "This box is not available in the current project on \(host.profile.displayName). It may have been purged, or its list could not be refreshed."
                : "This box ID prefix matches several boxes. Use the complete box link.")
        }
        return BoxLinkTarget(location: .init(connection: host.id, box: box.id), generation: host.workspace.connectionID)
    }

    /// Navigation only. Existing sidebar choices survive, and stopped or
    /// archived boxes keep their usual explicit start/restore controls.
    func openBoxLink(_ target: BoxLinkTarget) async throws {
        guard let host = session(target.location.connection), host.workspace.isConnected,
              host.workspace.connectionID == target.generation,
              host.workspace.sandboxes.contains(where: { $0.id == target.location.box && !$0.isDeleted }) else {
            throw DiscoboxError("The linked computer or box changed. Open the link again.")
        }
        activate(host.id)
        await host.workspace.selectBox(target.location.box)
        guard host.workspace.connectionID == target.generation, activeID == host.id,
              host.workspace.sandboxID == target.location.box else { throw CancellationError() }
        browser.requestReveal(target.location)
    }
}
