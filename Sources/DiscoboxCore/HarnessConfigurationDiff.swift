import Foundation

/// A bounded, line-based review of public harness settings. Large files retain
/// the full before/after text in the UI instead of blocking it with a huge diff.
public struct HarnessConfigurationDiff: Sendable {
    public enum Kind: Sendable { case unchanged, removed, added }
    public struct Line: Sendable {
        public let kind: Kind
        public let before: Int?
        public let after: Int?
        public let text: String
    }
    public let lines: [Line]
    public let usesFullText: Bool

    public init(before: String, after: String) {
        guard before.utf8.count + after.utf8.count <= 256 * 1024 else {
            lines = []; usesFullText = true; return
        }
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        guard old.count + new.count <= 2000, old.count * new.count <= 500_000 else {
            lines = []; usesFullText = true; return
        }
        let changes = new.difference(from: old)
        var removed = Set<Int>(), added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result: [Line] = [], previous = 0, current = 0
        while previous < old.count || current < new.count {
            if previous < old.count, removed.contains(previous) {
                result.append(.init(kind: .removed, before: previous + 1, after: nil, text: old[previous])); previous += 1
            } else if current < new.count, added.contains(current) {
                result.append(.init(kind: .added, before: nil, after: current + 1, text: new[current])); current += 1
            } else if previous < old.count, current < new.count {
                result.append(.init(kind: .unchanged, before: previous + 1, after: current + 1, text: old[previous])); previous += 1; current += 1
            }
        }
        lines = result; usesFullText = false
    }
}
