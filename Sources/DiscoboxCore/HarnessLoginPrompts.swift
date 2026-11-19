import Foundation

/// A pending episode belongs to one source box. Candidate IDs still identify
/// the immutable preview used for review and save.
public struct HarnessLoginPrompts: RawRepresentable, Equatable {
    public static let defaultsKey = "harnessSetupSheets.v1"

    public struct Scope: Hashable, Codable {
        let computer, project, harness, box: String

        public init?(computer: String, project: String, harness: String, box: String) {
            guard !computer.isEmpty, !project.isEmpty, !harness.isEmpty, !box.isEmpty else { return nil }
            self.computer = computer; self.project = project; self.harness = harness; self.box = box
        }
    }
    private enum State: Codable, Equatable {
        case offered
        case completed(String)
        case legacy(Set<String>)
    }
    private var entries: [Scope: State] = [:]
    public init() {}
    public init(rawValue: String) {
        let data = Data(rawValue.utf8)
        if let entries = try? JSONDecoder().decode([Scope: State].self, from: data) {
            self.entries = entries
        } else if let old = try? JSONDecoder().decode([String].self, from: data) {
            // Old versions recorded each displayed candidate individually.
            for key in old {
                guard let ids = try? JSONDecoder().decode([String].self, from: Data(key.utf8)), ids.count == 5,
                      let scope = Scope(computer: ids[0], project: ids[1], harness: ids[2], box: ids[3]) else { continue }
                var candidates: Set<String> = []
                if case .legacy(let known) = entries[scope] { candidates = known }
                candidates.insert(ids[4])
                entries[scope] = .legacy(candidates)
            }
        }
    }
    public var rawValue: String {
        (try? JSONEncoder().encode(entries)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
    public func hasOffered(_ scope: Scope, candidate: String) -> Bool {
        switch entries[scope] {
        case .offered: true
        case .legacy(let candidates): candidates.contains(candidate)
        case .completed(let id): id == candidate
        case nil: false
        }
    }
    public func completedCandidate(_ scope: Scope) -> String? {
        if case .completed(let id) = entries[scope] { return id }
        return nil
    }
    public mutating func offered(_ scope: Scope) { entries[scope] = .offered }
    public mutating func completed(_ scope: Scope, candidate: String) { entries[scope] = .completed(candidate) }

    public mutating func reconcile(computer: String, boxes: [Sandbox]) {
        guard !entries.isEmpty else { return }
        for box in boxes {
            guard let harness = box.config.harnessConfigId,
                  let scope = Scope(computer: computer, project: box.projectId, harness: harness, box: box.id),
                  entries[scope] != nil else { continue }
            let status = box.runtime.agentStatus ?? .null
            // Losing selection, disconnecting, or missing agent metadata is
            // not evidence that the pending changes were resolved.
            if box.isDeleted || (["clean", "none", "saved", "discarded", "superseded"].contains(status["harnessConfigState"].string)
                && status["harnessConfigCandidate"].string.isEmpty) {
                entries.removeValue(forKey: scope)
            }
        }
    }
}
