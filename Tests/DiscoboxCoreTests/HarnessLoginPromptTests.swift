import Foundation
import Testing
@testable import DiscoboxCore

@Test func loginPromptsRequireAPendingCredentialAndAreScopedToTheSource() throws {
    var object: [String: JSONValue] = [
        "state": .string("pending"), "harnessConfigId": .string("claude"),
        "candidateId": .string("candidate"), "credentials": .array([.object(["type": .string("oauth")])])
    ]
    let preview: JSONValue = .object(object)
    func key(_ value: JSONValue = preview, computer: String = "unix://", project: String = "p", harness: String = "claude", box: String = "b") -> String? {
        HarnessLoginPrompts.key(preview: value, computer: computer, project: project, harness: harness, box: box)
    }
    let identity = try #require(key())
    let stored = HarnessLoginPrompts.recording(identity, in: "[]")
    #expect(HarnessLoginPrompts.contains(identity, in: stored))
    #expect(HarnessLoginPrompts.recording(identity, in: stored) == stored)
    for other in [key(computer: "iroh://other"), key(project: "other"), key(box: "other")] {
        #expect(!HarnessLoginPrompts.contains(try #require(other), in: stored))
    }
    #expect(key(harness: "other") == nil)
    #expect(key(project: "") == nil)
    object["candidateId"] = .string("new")
    #expect(!HarnessLoginPrompts.contains(try #require(key(.object(object))), in: stored))
    object["credentials"] = .array([])
    object["files"] = .array([.object(["path": .string("settings.json")])])
    #expect(key(.object(object)) == nil)
    object["credentials"] = preview["credentials"]
    for state in ["saved", "saved-handoff-pending", "discarded", "unavailable"] {
        object["state"] = .string(state)
        #expect(key(.object(object)) == nil)
    }
}

@Test func loginPromptHistoryIsBoundedAndInvalidPreferencesRecover() throws {
    var stored = "invalid"
    for index in 0..<300 { stored = HarnessLoginPrompts.recording(String(index), in: stored) }
    let keys = try JSONDecoder().decode([String].self, from: Data(stored.utf8))
    #expect(keys.count == 256)
    #expect(keys.first == "44" && keys.last == "299")
    #expect(!HarnessLoginPrompts.contains("0", in: stored))
}
