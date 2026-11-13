import Foundation
import Testing
@testable import DiscoboxCore

@Test func approvalFormatsStaySeparateAndUnknownBindingShapesFailClosed() {
    let legacy = ApprovalItem(kind: "credential", credential: .object(["id": .string("r"), "policy": .object(["future": .bool(true)])]))
    #expect(legacy.presentation == .legacyCredential)
    for parts: [String: JSONValue] in [["use": .object([:])], ["delegate": .object([:])], ["use": .object([:]), "delegate": .object([:])]] {
        #expect(ApprovalItem(kind: "credential", credential: .object(parts)).presentation == .bindingCredential)
    }
    for parts: [String: JSONValue] in [["use": .null], ["use": .string("future")], ["use": .object([:]), "delegate": .string("future")]] {
        #expect(ApprovalItem(kind: "credential", credential: .object(parts)).presentation == .unsupported)
    }
    #expect(ApprovalItem(kind: "future").presentation == .unsupported)
    #expect(ApprovalItem(kind: "trust").presentation == .certificate)
}

@Test func tokenStorageUsesCredentialObjectsAndKeepsProtocolFieldsSeparate() throws {
    let current = try TokenCredentialPayload.current(name: "MCP", value: "fixture-token", routes: [.object(["hosts": .array([.string("example.test")])])])
    let legacy = try TokenCredentialPayload.legacy(name: "MCP", value: "fixture-token", host: "example.test", maximum: 3600)
    for body in [current, legacy] {
        #expect(body["value"]["token"].string == "fixture-token")
        #expect(body["type"].string == "token")
    }
    #expect(current["maxGrantTTLSeconds"] == .null && current["host"] == .null)
    #expect(legacy["maxBindingTTLSeconds"] == .null && legacy["routes"] == .null)
    #expect(throws: DiscoboxError.self) { try TokenCredentialPayload.current(name: "", value: "fixture-token", routes: []) }
    #expect(throws: DiscoboxError.self) { try TokenCredentialPayload.legacy(name: "MCP", value: "fixture-token", host: "", maximum: 3600) }
}

@Test func legacyGrantPreservesPolicyWithoutEditingSharedRestrictions() throws {
    let policy: JSONValue = .object(["futurePolicy": .array([.object(["scope": .string("read"), "unknown": .bool(true)])])])
    let body = try LegacyCredentialDecision.payload(request: .object(["policy": policy]), secretID: "sec", duration: ApprovalDuration.automatic, maximum: 1800)
    #expect(body == .object(["secretId": .string("sec"), "policy": policy]))
    #expect(throws: DiscoboxError.self) { try LegacyCredentialDecision.payload(request: .null, secretID: "sec", duration: "7200", maximum: 1800) }
}

@Test func sharedCredentialLimitsUseOnlyTheirOwnProtocolFields() throws {
    let old: JSONValue = .object(["id": .string("sec"), "maxGrantTTLSeconds": .number(3600)])
    let current: JSONValue = .object(["id": .string("sec"), "maxBindingTTLSeconds": .number(3600)])
    #expect(try CredentialLimits.payload(secret: old, seconds: "1800", host: "example.test")["limits"] == .object(["maxGrantTTLSeconds": .number(1800), "host": .string("example.test")]))
    #expect(try CredentialLimits.payload(secret: current, seconds: "1800", host: "ignored")["limits"] == .object(["maxBindingTTLSeconds": .number(1800)]))
    #expect(throws: DiscoboxError.self) { try CredentialLimits.payload(secret: current, seconds: "-1", host: "") }
}
