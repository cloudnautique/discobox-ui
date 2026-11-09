import Foundation
import Testing
@testable import DiscoboxCore

private func maintenanceBox(_ runtime: String) throws -> Sandbox {
    try JSONDecoder().decode(Sandbox.self, from: Data("{\"id\":\"box\",\"projectId\":\"project\",\"displayName\":\"Box\",\"config\":{},\"runtime\":\(runtime)}".utf8))
}

@Test func upgradeIndicatorsUseTheServerFlagAcrossImageAndBundleVersions() throws {
    for metadata in [
        #"{"available":true,"reason":"imageDigestChanged","targetImage":"legacy-image","targetImageDigest":"sha256:legacy"}"#,
        #"{"available":true,"reason":"platformBundleDigestChanged","targetPlatformBundleDigest":"sha256:platform","futureField":{"anything":true}}"#
    ] {
        let box = try maintenanceBox("{\"state\":\"ready\",\"runtimeState\":\"running\",\"upgrade\":\(metadata)}")
        #expect(box.upgradeAvailable)
        #expect(box.upgradeTooltip?.contains("Upgrade…") == true)
        #expect(!box.needsRepair)
        #expect(box.repairTooltip == nil)
    }
    for metadata in ["", #", "upgrade":null"#, #", "upgrade":{"available":false,"targetImage":"something-new"}"#] {
        let box = try maintenanceBox("{\"state\":\"ready\"\(metadata)}")
        #expect(!box.upgradeAvailable)
        #expect(box.upgradeTooltip == nil)
    }
}

@Test func failedBoxesExplainRepairAndUnavailableImagesPointToUpgrade() throws {
    let failed = try maintenanceBox(#"{"state":"failed","errorMessage":"The container could not be created."}"#)
    #expect(failed.needsRepair)
    #expect(failed.repairTooltip?.contains("The container could not be created.") == true)
    #expect(failed.repairTooltip?.contains("Repair…") == true)
    let image = try maintenanceBox(#"{"state":"failed","displayState":"error","runtimeState":"running","errorReason":"image_unavailable","errorMessage":"Pinned image was removed.","upgrade":{"available":true}}"#)
    #expect(image.needsRepair && image.upgradeAvailable)
    #expect(image.repairTooltip?.contains("Pinned image was removed.") == true)
    #expect(image.repairTooltip?.contains("Upgrade…") == true)
}

@Test func repairIndicatorsRespectDisplayStateAndDoNotFlagSuccessfulOrHealthyBoxes() throws {
    let repairing = try maintenanceBox(#"{"state":"failed","displayState":"repairing","errorMessage":"Old failure","upgrade":{"available":true},"automaticRepair":{"failure":"Old failure","startedAt":"2026-11-06T12:00:00Z"}}"#)
    #expect(repairing.isRepairing && !repairing.needsRepair)
    #expect(repairing.repairTooltip?.hasPrefix("Repair in progress.") == true)
    #expect(repairing.repairTooltip?.contains("Old failure") == false)
    #expect(!repairing.upgradeAvailable)
    for runtime in [
        #"{"state":"ready","runtimeState":"stopped"}"#,
        #"{"state":"failed","displayState":"running","errorMessage":"A stale failure"}"#,
        #"{"state":"pending","displayState":"starting","errorMessage":"Waiting for pool upgrade"}"#,
        #"{"state":"ready","displayState":"running","automaticRepair":{"failure":"Old failure","landedAt":"2026-11-06T12:01:00Z"}}"#
    ] {
        let box = try maintenanceBox(runtime)
        #expect(!box.needsRepair && !box.isRepairing)
        #expect(box.repairTooltip == nil)
    }
}

@Test func archivedDeletedAndBusyBoxesDoNotAdvertiseUnavailableUpgradeActions() throws {
    for state in ["archived", "deleted", "deleting", "archiving", "starting", "stopping"] {
        let box = try maintenanceBox("{\"state\":\"failed\",\"displayState\":\"\(state)\",\"upgrade\":{\"available\":true}}")
        #expect(!box.upgradeAvailable)
        #expect(box.upgradeTooltip == nil)
        #expect(!box.needsRepair)
    }
}

@Test func runningWarningKeepsCreatedBoxUsable() throws {
    let box = try maintenanceBox(#"{"state":"failed","displayState":"running","runtimeState":"running","errorMessage":"Optional background setup failed"}"#)
    #expect(box.isRunning)
    #expect(box.runningWarning == "Optional background setup failed")
    #expect(!box.needsRepair)
    let creation = BoxCreation(connection: UUID(), item: .init(location: .init(connection: "computer", box: box.id), computer: "Fixture", box: box, needsAttention: true))
    #expect(creation.phase == .ready)
}
