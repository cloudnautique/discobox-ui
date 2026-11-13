import Foundation
import Testing
@testable import DiscoboxCore

private func indicatorBox(agent: String? = "idle", kind: String = "", power: String = "running", state: String = "ready", display: String? = nil, warning: String? = nil, upgrade: Bool = false) throws -> Sandbox {
    var report: [String: JSONValue] = ["kind": .string(kind)]
    if let agent { report["state"] = .string(agent) }
    var runtime: [String: JSONValue] = ["state": .string(state), "runtimeState": .string(power),
        "agentStatus": .object(["sessions": .array([.object(["primary": .bool(true), "execStatus": .string("running"), "programStatus": .object(report)])])])]
    if let display { runtime["displayState"] = .string(display) }
    if let warning { runtime["errorMessage"] = .string(warning) }
    if upgrade { runtime["upgrade"] = .object(["available": .bool(true)]) }
    return try JSONDecoder().decode(Sandbox.self, from: JSONEncoder().encode(JSONValue.object([
        "id": .string("box"), "projectId": .string("project"), "displayName": .string("Task"), "config": .object([:]), "runtime": .object(runtime)
    ])))
}

@Test func runningLightsStayGreenWhenIdleFinishedOrActivityUnknown() throws {
    for state in ["working", "idle", "done", "future-state", nil] {
        let box = try indicatorBox(agent: state)
        let light = BoxIndicator(box: box, activity: .init(box: box))
        #expect(light.state == .on)
        #expect(light.isWorking == (state == "working"))
    }
}

@Test func attentionAndFailureLightsOverridePowerWithoutAnimating() throws {
    for kind in ["permission", "question", "auth", "other"] {
        let box = try indicatorBox(agent: "blocked", kind: kind)
        let light = BoxIndicator(box: box, activity: .init(box: box))
        #expect(light.state == .attention && !light.isWorking)
    }
    for box in [try indicatorBox(agent: "error"), try indicatorBox(state: "failed", display: "failed")] {
        let light = BoxIndicator(box: box, activity: .init(box: box, pendingRequests: box.needsRepair ? 2 : 0))
        #expect(light.state == .error && !light.isWorking)
    }
    let box = try indicatorBox(agent: "working")
    #expect(BoxIndicator(box: box, activity: .init(box: box, pendingRequests: 2)).state == .attention)
}

@Test func stoppedAndDisconnectedLightsNeverSuggestLiveWork() throws {
    for box in [try indicatorBox(agent: "working", power: "stopped"), try indicatorBox(state: "archived"), try indicatorBox(state: "deleted")] {
        let light = BoxIndicator(box: box, activity: .init(box: box))
        #expect(light.state == .off && !light.isWorking)
    }
    let box = try indicatorBox(agent: "working")
    let unavailable = BoxIndicator(box: box, activity: .init(box: box), reachable: false)
    #expect(unavailable.state == .unavailable && !unavailable.isWorking)
    let starting = try indicatorBox(power: "unknown", state: "pending", display: "starting")
    #expect(BoxIndicator(box: starting, activity: .init(box: starting)).state == .unavailable)
}

@Test func maintenanceStaysSeparateFromHealthyPowerAndReportedActivity() throws {
    let upgrade = try indicatorBox(agent: "working", upgrade: true)
    let healthy = BoxIndicator(box: upgrade, activity: .init(box: upgrade))
    #expect(upgrade.upgradeAvailable && healthy.state == .on && healthy.isWorking)
    let repairing = try indicatorBox(state: "failed", display: "repairing")
    #expect(repairing.isRepairing && !repairing.needsRepair)
    #expect(BoxIndicator(box: repairing, activity: .init(box: repairing)).state == .attention)
    let warning = try indicatorBox(agent: "working", warning: "Running with reduced resources")
    #expect(BoxIndicator(box: warning, activity: .init(box: warning)).state == .attention)
}
