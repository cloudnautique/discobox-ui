import Foundation

/// Projects the already filtered, sorted browser results into a forest.
/// A missing parent leaves its children at the top level of this view.
public struct BoxParentOutline {
    public struct Row: Identifiable {
        public var id: BoxLocation { item.location }
        public let item: ConnectedBox
        public let depth: Int
        public let childCount: Int
        public fileprivate(set) var attentionBelow = 0
    }

    private let parents: [BoxLocation: BoxLocation]
    private let rows: [Row]

    public init(_ items: [ConnectedBox]) {
        let projects = Dictionary(uniqueKeysWithValues: items.map { ($0.location, $0.box.projectId) })
        var parents: [BoxLocation: BoxLocation] = [:]
        for item in items {
            guard let id = item.box.parentSandboxId else { continue }
            let parent = BoxLocation(connection: item.location.connection, box: id)
            if projects[parent] == item.box.projectId { parents[item.location] = parent }
        }
        // A malformed cycle has no root. Break one edge so every box remains reachable.
        var checked: Set<BoxLocation> = []
        for item in items where !checked.contains(item.location) {
            var path: Set<BoxLocation> = []
            var next: BoxLocation? = item.location
            while let id = next, !checked.contains(id) {
                if !path.insert(id).inserted { parents[id] = nil; break }
                next = parents[id]
            }
            checked.formUnion(path)
        }
        self.parents = parents
        let groups = Dictionary(grouping: items) { parents[$0.location] }
        var pending = (groups[nil] ?? []).reversed().map { (item: $0, depth: 0) }
        var rows: [Row] = []
        while let (item, depth) = pending.popLast() {
            let children = groups[item.location] ?? []
            rows.append(Row(item: item, depth: depth, childCount: children.count))
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        let indices = Dictionary(uniqueKeysWithValues: rows.indices.map { (rows[$0].id, $0) })
        for index in rows.indices.reversed() {
            guard let parent = parents[rows[index].id], let parentIndex = indices[parent] else { continue }
            let attention = rows[index].attentionBelow + (rows[index].item.needsAttention ? 1 : 0)
            rows[parentIndex].attentionBelow += attention
        }
        self.rows = rows
    }

    public func ancestors(of location: BoxLocation) -> Set<BoxLocation> {
        var ancestors: Set<BoxLocation> = []
        var parent = parents[location]
        while let id = parent { ancestors.insert(id); parent = parents[id] }
        return ancestors
    }

    public func visibleRows(collapsed: Set<BoxLocation>) -> [Row] {
        guard !collapsed.isEmpty else { return rows }
        var collapsedDepth: Int?
        return rows.filter { row in
            if let collapsedDepth, row.depth > collapsedDepth { return false }
            collapsedDepth = collapsed.contains(row.id) ? row.depth : nil
            return true
        }
    }
}
