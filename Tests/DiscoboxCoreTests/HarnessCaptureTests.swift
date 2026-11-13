import Foundation
import Testing
@testable import DiscoboxCore

@Test func harnessCaptureNormalStatesNeedNoOwnerButCannotEnableSaving() {
    for state in ["unsupported", "initializing", "unavailable"] {
        let preview: JSONValue = .object(["state": .string(state)])
        #expect(HarnessCapture.accepts(preview, harnessID: "h"))
        #expect(!HarnessCapture.canSave(preview))
        #expect(HarnessCapture.explanation(preview) != nil)
        #expect(!HarnessCapture.accepts(.object(["state": .string(state), "candidateId": .string("c")]), harnessID: "h"))
    }
    #expect(!HarnessCapture.accepts(.object(["state": .string("pending")]), harnessID: "h"))
    #expect(!HarnessCapture.accepts(.object(["state": .string("unsupported"), "harnessConfigId": .string("other")]), harnessID: "h"))
    let noop: JSONValue = .object(["state": .string("pending"), "candidateId": .string("c"), "harnessConfigId": .string("h")])
    #expect(!HarnessCapture.canSave(noop))
    #expect(HarnessCapture.explanation(noop)?.contains("nothing new") == true)
    #expect(HarnessCapture.canSave(.object(["state": .string("saved-handoff-pending"), "candidateId": .string("c")])))
}

@Test func launchDefaultsStayOffAndSeparateComputersProjectsAndAccounts() {
    let key = HarnessLaunchDefaults.key(computer: "unix://", project: "p", harness: "codex")
    #expect(!HarnessLaunchDefaults.enabled("{}", key: key))
    let stored = HarnessLaunchDefaults.setting("{}", key: key, enabled: true)
    #expect(HarnessLaunchDefaults.enabled(stored, key: key))
    for other in [HarnessLaunchDefaults.key(computer: "iroh://remote", project: "p", harness: "codex"),
                  HarnessLaunchDefaults.key(computer: "unix://", project: "other", harness: "codex"),
                  HarnessLaunchDefaults.key(computer: "unix://", project: "p", harness: "codex-work")] {
        #expect(!HarnessLaunchDefaults.enabled(stored, key: other))
    }
    #expect(!HarnessLaunchDefaults.enabled(HarnessLaunchDefaults.setting(stored, key: key, enabled: false), key: key))
}
