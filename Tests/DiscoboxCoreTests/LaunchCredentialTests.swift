import Foundation
import Testing
@testable import DiscoboxCore

@Test func launchCredentialsPreserveTokenTextAndUseTheSecretChannel() throws {
    let token = "fixture@token\"with\\escapes"
    let credential = LaunchCredential(environment: " OBOT_MCP_TOKEN ", host: " Demo.On-Obot.AI ", value: token)
    let encoded = try LaunchCredential.payload([credential])
    let payload = try #require(encoded)
    #expect(payload["secrets"].array.first?["env"].string == "OBOT_MCP_TOKEN")
    #expect(payload["secrets"].array.first?["host"].string == "demo.on-obot.ai")
    #expect(payload["secrets"].array.first?["value"].string == token)
    #expect(!String(describing: credential).contains(token))
    #expect(!String(reflecting: credential).contains(token))
    #expect(try LaunchCredential.payload([]) == nil)
}

@Test func launchCredentialsRejectAmbiguousOrUnboundedInputsWithoutLeakingValues() {
    let invalid = [
        LaunchCredential(environment: "BAD-NAME", host: "example.test", value: "fixture-sensitive"),
        LaunchCredential(environment: "TOKEN", host: "https://example.test/path", value: "fixture-sensitive"),
        LaunchCredential(environment: "TOKEN", host: "example.test:443", value: "fixture-sensitive"),
        LaunchCredential(environment: "TOKEN", host: "*", value: "fixture-sensitive"),
        LaunchCredential(environment: "TOKEN", host: "", value: "fixture-sensitive"),
        LaunchCredential(environment: "TOKEN", host: "example.test", value: "  "),
        LaunchCredential(environment: "TOKEN", host: "example.test", value: "fixture-sensitive\0"),
        LaunchCredential(environment: "TOKEN", host: "example.test", value: String(repeating: "a", count: 16_385))
    ]
    for credential in invalid {
        do { _ = try LaunchCredential.payload([credential]); Issue.record("Invalid launch credential accepted") }
        catch { #expect(!error.localizedDescription.contains("fixture-sensitive")) }
    }
    let duplicate = LaunchCredential(environment: "TOKEN", host: "example.test", value: "fixture-sensitive")
    #expect(throws: DiscoboxError.self) { try LaunchCredential.payload([duplicate, duplicate]) }
    #expect(throws: DiscoboxError.self) { try LaunchCredential.payload(Array(repeating: duplicate, count: 17)) }
}
