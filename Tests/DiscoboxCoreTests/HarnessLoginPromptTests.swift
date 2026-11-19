import Foundation
import Testing
@testable import DiscoboxCore

private func scope(_ computer: String = "local", _ project: String = "p", _ harness: String = "h", _ box: String = "b") throws -> HarnessLoginPrompts.Scope {
    try #require(.init(computer: computer, project: project, harness: harness, box: box))
}

@Test func laterSurvivesCandidateChangesAndRestartUntilTheEpisodeEnds() throws {
    let source = try scope()
    var history = HarnessLoginPrompts()
    history.offered(source)
    history = HarnessLoginPrompts(rawValue: history.rawValue)
    #expect(history.hasOffered(source, candidate: "another-edit"))
    for other in try [scope("laptop"), scope("local", "other"), scope("local", "p", "other"), scope("local", "p", "h", "other")] {
        #expect(!history.hasOffered(other, candidate: "another-edit"))
    }
    history.completed(source, candidate: "saved")
    history = HarnessLoginPrompts(rawValue: history.rawValue)
    #expect(history.completedCandidate(source) == "saved")
    #expect(history.hasOffered(source, candidate: "saved"))
    #expect(!history.hasOffered(source, candidate: "next"))
}

@Test func onlyConfirmedResolutionRearmsADeferredHarness() throws {
    let source = try scope()
    var history = HarnessLoginPrompts()
    history.offered(source)
    func report(_ state: String) throws -> Sandbox {
        try JSONDecoder().decode(Sandbox.self, from: Data("""
        {"id":"b","projectId":"p","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready","agentStatus":{"harnessConfigState":"\(state)"}}}
        """.utf8))
    }
    history.reconcile(computer: "local", boxes: [])
    history.reconcile(computer: "local", boxes: try ["", "unavailable", "initializing", "pending"].map(report))
    history.reconcile(computer: "other", boxes: [try report("clean")])
    #expect(history.hasOffered(source, candidate: "updated"))
    for state in ["saved", "discarded", "clean"] {
        history.offered(source)
        history.reconcile(computer: "local", boxes: [try report(state)])
        #expect(!history.hasOffered(source, candidate: "fresh"))
    }
}

@Test func existingPresentationHistoryHonorsOnlyMatchingLegacyCandidates() throws {
    let oldKey = try JSONEncoder().encode(["local","p","h","b","seen"])
    let old = try JSONEncoder().encode([String(decoding: oldKey, as: UTF8.self)])
    let history = HarnessLoginPrompts(rawValue: String(decoding: old, as: UTF8.self))
    let source = try scope()
    #expect(history.hasOffered(source, candidate: "seen"))
    #expect(!history.hasOffered(source, candidate: "new"))
    #expect(HarnessLoginPrompts(rawValue: "invalid") == HarnessLoginPrompts())
}
