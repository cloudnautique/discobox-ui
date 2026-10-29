import Foundation

/// Owns retained audit data away from the UI actor. The byte budget covers UTF-8
/// text plus an allowance for each record; it is not a process-memory ceiling.
public actor AuditBuffer {
    public struct Snapshot: Sendable {
        public let records: [AuditRecord]
        public let bytes: Int
        public let limited: Bool
        public let version: Int
    }
    private let maxBytes: Int
    private let maxRecords: Int
    private var records: [AuditRecord] = []
    private var bytes = 0
    private var limited = false
    private var version = 0

    public init(maxBytes: Int = 32 * 1024 * 1024, maxRecords: Int = 50_000) {
        self.maxBytes = max(0, maxBytes)
        self.maxRecords = max(0, maxRecords)
    }
    public func merge(_ incoming: [AuditRecord]) -> Snapshot {
        if !incoming.isEmpty {
            var merged = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
            for record in incoming { merged[record.id] = record }
            let sorted = merged.values.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order > $1.order }
            var retained: [AuditRecord] = []
            var retainedBytes = 0
            for record in sorted {
                let cost = Self.byteCost(record)
                guard retained.count < maxRecords, cost <= maxBytes - retainedBytes else { break }
                retained.append(record)
                retainedBytes += cost
            }
            limited = limited || retained.count < sorted.count
            if retained != records {
                records = retained
                bytes = retainedBytes
                version += 1
            }
        }
        return Snapshot(records: records, bytes: bytes, limited: limited, version: version)
    }
    public static func byteCost(_ record: AuditRecord) -> Int {
        128 + record.id.utf8.count + record.source.utf8.count + record.time.utf8.count + record.summary.utf8.count + record.detail.utf8.count
    }
    /// Call from background work. Cooperative cancellation avoids scanning the
    /// remaining history when the user changes their query or leaves the tab.
    public static func filter(_ records: [AuditRecord], source: String, query: String) throws -> [AuditRecord] {
        var matches: [AuditRecord] = []
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            if (source == "All" || record.source == source) && (query.isEmpty || record.summary.localizedCaseInsensitiveContains(query) || record.detail.localizedCaseInsensitiveContains(query)) {
                matches.append(record)
            }
        }
        try Task.checkCancellation()
        return matches
    }
}
