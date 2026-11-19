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
    var usageReads = 0
    let truncated: Bool
    init(truncated: Bool = false) { self.truncated = truncated }
    func perform(_ request: BridgeRequest) async throws -> Data {
        switch request.operation {
        case .harnesses: return Data(#"{"harnessConfigs":[{"id":"h","name":"Codex work","configured":true}]}"#.utf8)
        case .usage:
            usageReads += 1
            if request.usagePage?.host == "api.anthropic.com" { return Data(#"{"records":[],"through":"","full":false}"#.utf8) }
            if request.usagePage?.after == "http_2" {
                return Data(#"{"records":[{"id":"http_3","poolId":"pool","sandboxId":"box1","createdAt":"2026-10-27T18:00:00Z","provider":"codex"}],"through":"http_3","full":false}"#.utf8)
            }
            return Data(#"{"records":[{"id":"http_2","poolId":"pool","sandboxId":"box2","createdAt":"2026-10-27T17:00:00Z","provider":"codex"},{"id":"http_1","poolId":"pool","sandboxId":"box1","createdAt":"2026-10-27T16:00:00Z","provider":"codex"}],"through":"http_2","full":false}"#.utf8)
        case .auditBody:
            bodyReads += 1
            let percent = request.recordID == "http_3" ? 83 : 70
            return try JSONSerialization.data(withJSONObject: ["text": #"{"rate_limit":{"primary_window":{"used_percent":\#(percent)}}}"#, "truncated": truncated])
        default: throw DiscoboxError("Unexpected operation")
        }
    }
}

@MainActor @Test func quotaCollectionDeduplicatesHarnessAcrossBoxesAndRefreshes() async throws {
    let boxes = try JSONDecoder().decode([Sandbox].self, from: Data(#"[{"id":"box1","projectId":"p","poolId":"pool","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}},{"id":"box2","projectId":"p","poolId":"pool","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}}]"#.utf8))
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


@MainActor @Test func usagePollCadenceSurvivesRepeatedRefreshRequests() async {
    var now = Date()
    let usage = HarnessUsage(now: { now })
    let client = UsageFixture()
    let boxes = try! JSONDecoder().decode([Sandbox].self, from: Data(#"[{"id":"box1","projectId":"p","poolId":"pool","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}}]"#.utf8))
    await usage.refresh(client: client, project: "p", boxes: boxes)
    for _ in 0..<10 { await usage.refresh(client: client, project: "p", boxes: boxes) }
    #expect(await client.usageReads == 2)
    #expect(usage.snapshots["h"]?.windows.first?.usedPercent == 70)
    now = now.addingTimeInterval(61)
    await usage.refresh(client: client, project: "p", boxes: boxes)
    #expect(await client.usageReads == 4)
    #expect(usage.snapshots["h"]?.windows.first?.usedPercent == 83)
}

@MainActor @Test func cancellingUsageStopsBackgroundWorkWithoutHoldingUIActor() async {
    let usage = HarnessUsage()
    let client = SlowUsageFixture()
    let boxes = try! JSONDecoder().decode([Sandbox].self, from: Data(#"[{"id":"box","projectId":"p","poolId":"pool","displayName":"Box","config":{"harnessConfigId":"h"},"runtime":{"state":"ready"}}]"#.utf8))
    let poll = Task { await usage.refresh(client: client, project: "p", boxes: boxes, configuredHarnesses: []) }
    while !(await client.started) { await Task.yield() }
    // This main-actor test can continue while a usage request remains blocked.
    #expect(usage.isLoading)
    poll.cancel()
    await poll.value
    #expect(await client.cancelled)
    #expect(!usage.isLoading)
    #expect(usage.snapshots.isEmpty)
}

private actor SlowUsageFixture: DiscoboxClient {
    var started = false
    var cancelled = false
    func perform(_ request: BridgeRequest) async throws -> Data {
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true; throw error }
        return Data(#"{"records":[],"missing":[]}"#.utf8)
    }
}

private actor BacklogFixture: DiscoboxClient {
    private(set) var pages: [BridgeRequest.UsagePage] = []
    private(set) var bodies: [String] = []
    var round = 0
    func nextRound() { round += 1 }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .usage, let page = request.usagePage {
            pages.append(page)
            var result: [String: Any] = ["records": [], "through": page.after ?? "", "full": false]
            if page.host == "chatgpt.com" {
                if round == 0 {
                    result["through"] = "http_10"  // Scanned rows without a quota candidate.
                } else {
                    let first = Int((page.after ?? "").dropFirst(5))! + 1
                    let ids = Array(first..<(first + page.limit)).filter { $0 <= 110 }
                    result["records"] = ids.map { id in
                        ["poolId": "p", "sandboxId": "box" + String(id), "id": "http_" + String(id),
                         "createdAt": "2026-10-27T17:00:00Z", "provider": "codex"]
                    }
                    result["through"] = ids.last.map { "http_" + String($0) } ?? page.after
                    result["full"] = ids.count == page.limit
                }
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        let id = try #require(request.recordID)
        bodies.append(id)
        if round == 1 && id == "http_74" { throw URLError(.timedOut) }
        return Data(#"{"text":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":12}}}"}"#.utf8)
    }
}

@MainActor @Test func usageRetainsAFullCandidatePageAcrossCyclesAndRetriesWithoutRescanningItsPrefix() async throws {
    var date = Date()
    let usage = HarnessUsage(now: { date }), client = BacklogFixture()
    let rows: [[String: Any]] = (11...110).map { id in
        ["id": "box" + String(id), "poolId": "p", "projectId": "proj", "config": ["harnessConfigId": "h" + String(id)],
         "displayName": "fixture", "runtime": ["state": "ready"]]
    }
    let boxes = try JSONDecoder().decode([Sandbox].self, from: JSONSerialization.data(withJSONObject: rows))
    for _ in 0..<28 {
        let oldPages = await client.pages.count, oldBodies = await client.bodies.count
        await usage.refresh(client: client, project: "proj", boxes: boxes, configuredHarnesses: [])
        #expect(await client.pages.count - oldPages <= 4)
        #expect(await client.bodies.count - oldBodies <= 4)
        await client.nextRound()
        date += 61
    }
    let pages = await client.pages.filter { $0.host == "chatgpt.com" }
    #expect(pages[1].after == "http_10" && pages[1].limit == 100)
    #expect(pages[2].after == "http_74")
    #expect(usage.snapshots.count == 100)
    #expect(await client.bodies.filter { $0 == "http_74" }.count == 2)
}
