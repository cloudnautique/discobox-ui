import Foundation
import Testing
@testable import DiscoboxCore

private func auditRow(_ id: String, order: Double, detail: String = "metadata", source: String = "HTTP") -> AuditRecord {
    AuditRecord(id: id, source: source, time: "2026-10-28T12:00:00Z", order: order, summary: "Event " + id, detail: detail)
}

@Test func auditRetentionBoundsBytesAndKeepsNewestRecords() async {
    let row = auditRow("a", order: 1, detail: String(repeating: "é", count: 1024))
    let cost = AuditBuffer.byteCost(row)
    let buffer = AuditBuffer(maxBytes: cost * 2, maxRecords: 50_000)
    let first = await buffer.merge([row, auditRow("b", order: 2, detail: row.detail)])
    #expect(first.records.map(\.id) == ["b", "a"])
    #expect(first.bytes == cost * 2)
    let next = await buffer.merge([auditRow("c", order: 3, detail: row.detail)])
    #expect(next.records.map(\.id) == ["c", "b"])
    #expect(next.bytes <= cost * 2)
    #expect(next.limited)
    let unchanged = await buffer.merge([])
    #expect(unchanged.version == next.version)
    let duplicate = await buffer.merge([auditRow("c", order: 3, detail: row.detail)])
    #expect(duplicate.version == next.version)
}

@Test func auditRetentionCountsUpdatesAndDeterministicTies() async {
    let buffer = AuditBuffer(maxRecords: 2)
    let first = await buffer.merge([auditRow("b", order: 1), auditRow("a", order: 1), auditRow("old", order: 0)])
    #expect(first.records.map(\.id) == ["a", "b"])
    #expect(first.limited)
    let update = await buffer.merge([auditRow("a", order: 1, detail: "changed")])
    #expect(update.records.first?.detail == "changed")
    #expect(update.version > first.version)
    let oversized = AuditBuffer(maxBytes: 10)
    let empty = await oversized.merge([auditRow("huge", order: 2)])
    #expect(empty.records.isEmpty)
    #expect(empty.bytes == 0)
    #expect(empty.limited)
}

@Test func auditSearchMatchesDetailAndSourceAndSupportsCancellation() async throws {
    let records = [auditRow("a", order: 2, detail: "Café credential"), auditRow("b", order: 1, detail: "credential", source: "Hooks")]
    #expect(try AuditBuffer.filter(records, source: "HTTP", query: "CAFÉ").map(\.id) == ["a"])
    #expect(try AuditBuffer.filter(records, source: "All", query: "credential").count == 2)
    #expect(try AuditBuffer.filter(records, source: "All", query: "").count == 2)
    #expect(try AuditBuffer.filter(records, source: "All", query: "missing").isEmpty)
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try AuditBuffer.filter(records, source: "All", query: "credential")
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled search returned results") }
    catch is CancellationError { }
}
