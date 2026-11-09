import Testing
@testable import DiscoboxCore

@Test func harnessDiffPreservesBothVersionsWithRepeatedAndMovedLines() {
    let before = "{\n  a\n  repeat\n  b\n  repeat\n}"
    let after = "{\n  b\n  repeat\n  changed\n  repeat\n}"
    let diff = HarnessConfigurationDiff(before: before, after: after)
    #expect(!diff.usesFullText)
    #expect(diff.lines.filter { $0.kind != .added }.map(\.text).joined(separator: "\n") == before)
    #expect(diff.lines.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") == after)
    #expect(diff.lines.compactMap(\.before) == Array(1...6))
    #expect(diff.lines.compactMap(\.after) == Array(1...6))
    #expect(diff.lines.contains { $0.kind == .removed })
    #expect(diff.lines.contains { $0.kind == .added && $0.text == "  changed" })
}

@Test func harnessDiffDistinguishesCreationRemovalAndFinalNewline() {
    let created = HarnessConfigurationDiff(before: "", after: "settings\n")
    #expect(created.lines.count == 2 && created.lines.allSatisfy { $0.kind == .added })
    let removed = HarnessConfigurationDiff(before: "settings", after: "")
    #expect(removed.lines.count == 1 && removed.lines[0].kind == .removed)
    let newline = HarnessConfigurationDiff(before: "settings", after: "settings\n")
    #expect(newline.lines.last?.kind == .added && newline.lines.last?.text == "")
    #expect(HarnessConfigurationDiff(before: "", after: "").lines.isEmpty)
}

@Test func harnessDiffKeepsUnchangedFilesQuietAndUnicodeIntact() {
    let content = "\t☕️\r\n  日本語\n"
    let diff = HarnessConfigurationDiff(before: content, after: content)
    #expect(diff.lines.allSatisfy { $0.kind == .unchanged })
    #expect(diff.lines.map(\.text).joined(separator: "\n") == content)
}

@Test func harnessDiffFallsBackBeforeExpensiveLargeComparisons() {
    #expect(HarnessConfigurationDiff(before: String(repeating: "a", count: 256 * 1024 + 1), after: "").usesFullText)
    let many = Array(repeating: "settings", count: 800).joined(separator: "\n")
    #expect(HarnessConfigurationDiff(before: many, after: many).usesFullText)
    #expect(HarnessConfigurationDiff(before: "", after: String(repeating: "line\n", count: 2001)).usesFullText)
}
