import Foundation
import Testing
@testable import DiscoboxCore

@Test func quotaAdaptersRejectUnknownAndInvalidValues() {
    let codex = QuotaParser.parse(#"{"rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":30,"limit_window_seconds":604800}}}"#, provider: "codex")
    #expect(codex.map(\.usedPercent) == [70, 30])
    #expect(codex.map(\.title) == ["5-hour window", "Weekly"])
    #expect(codex.first?.resetsAt == Date(timeIntervalSince1970: 1800000000))
    let claude = QuotaParser.parse(#"{"five_hour":{"utilization":40,"resets_at":"2026-10-27T17:00:00Z"},"seven_day":{"utilization":0},"seven_day_sonnet":null}"#, provider: "claude")
    #expect(claude.map(\.usedPercent) == [40, 0])
    #expect(claude.first?.resetsAt != nil)
    for text in ["{}", "not JSON", #"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":101}}"#] {
        #expect(QuotaParser.parse(text, provider: "claude").isEmpty)
    }
}

private actor UsageFixture: DiscoboxClient {
    var bodyReads = 0
    let truncated: Bool
    init(truncated: Bool = false) { self.truncated = truncated }
    func perform(_ request: BridgeRequest) async throws -> Data {
        switch request.operation {
        case .harnesses: return Data(#"{"harnessConfigs":[{"id":"h","name":"Codex work","configured":true}]}"#.utf8)
        case .usage: return Data(#"{"records":[{"id":"http_2","poolId":"pool","sandboxId":"box2","createdAt":"2026-10-27T17:00:00Z","provider":"codex"},{"id":"http_1","poolId":"pool","sandboxId":"box1","createdAt":"2026-10-27T16:00:00Z","provider":"codex"}],"missing":[]}"#.utf8)
        case .auditBody:
            bodyReads += 1
            return try JSONSerialization.data(withJSONObject: ["text": #"{"rate_limit":{"primary_window":{"used_percent":70}}}"#, "truncated": truncated])
        default: throw DiscoboxError("Unexpected operation")
        }
    }
}

@MainActor @Test func quotaCollectionDeduplicatesHarnessAcrossBoxesAndRefreshes() async throws {
    let boxes = try JSONDecoder().decode([Sandbox].self, from: Data(#"[{"id":"box1","projectId":"p","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}},{"id":"box2","projectId":"p","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}}]"#.utf8))
    let client = UsageFixture()
    let usage = HarnessUsage()
    await usage.refresh(client: client, project: "p", boxes: boxes)
    await usage.refresh(client: client, project: "p", boxes: boxes)
    #expect(await client.bodyReads == 1)
    #expect(usage.snapshots.count == 1)
    #expect(usage.snapshots["h"]?.windows.first?.usedPercent == 70)
    let truncated = HarnessUsage()
    await truncated.refresh(client: UsageFixture(truncated: true), project: "p", boxes: boxes)
    #expect(truncated.snapshots.isEmpty)
    #expect(!truncated.notices.isEmpty)
}

@Test func claudeRecordedHeadersUseFractionalUtilization() {
    let windows = QuotaParser.headers([
        "Anthropic-Ratelimit-Unified-5h-Utilization": ["0.1"],
        "Anthropic-Ratelimit-Unified-7d-Utilization": ["0.03"],
        "Anthropic-Ratelimit-Unified-5h-Reset": ["1793142000"],
        "anthropic-ratelimit-requests-remaining": ["100"]
    ])
    #expect(windows.map(\.usedPercent) == [10, 3])
    #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1793142000))
    #expect(QuotaParser.headers(["anthropic-ratelimit-unified-5h-utilization": ["NaN"]]).isEmpty)
    #expect(QuotaParser.headers(["anthropic-ratelimit-unified-5h-utilization": ["10"]]).isEmpty)
}
