import Foundation
import Testing
@testable import DiscoboxCore

struct CredentialDecisionTests {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    @Test func explicitDecisionsAndModernLifetimes() throws {
        let request = try json(#"{"sandboxId":"box","envName":"TOKEN","use":{"routes":[{"hosts":["api.test"],"mcp":{"tools":["read_*"]}}]},"delegate":{}}"#)
        let secret = try json(#"{"id":"secret","maxBindingTTLSeconds":1800}"#)
        var use = CredentialPartDecision(), delegate = CredentialPartDecision()
        use.decision = "approve"
        #expect(throws: DiscoboxError.self) { try CredentialDecision.payload(request: request, secret: secret, held: [], use: use, delegate: delegate) }
        delegate.decision = "deny"
        let automatic = try CredentialDecision.payload(request: request, secret: secret, held: [], use: use, delegate: delegate)
        #expect(automatic["use"]["ttlSeconds"] == .null)
        #expect(automatic["delegate"] == .object(["decision": .string("deny")]))
        #expect(automatic["use"]["routes"] == .null) // server retains the exact requested routes
        use.duration = "1800"
        #expect(try use.fields(use: true, secret: secret)["ttlSeconds"] == .number(1800))
        use.duration = "3600"
        #expect(throws: DiscoboxError.self) { try use.fields(use: true, secret: secret) }
        use.duration = "0"
        #expect(throws: DiscoboxError.self) { try use.fields(use: true, secret: secret) }
    }
    @Test func holdersAndRawDeliveryCannotBeBypassed() throws {
        let request = try json(#"{"sandboxId":"box","envName":"TOKEN","use":{}}"#)
        let held = try json(#"[{"secretId":"original","from":"sandbox","fromId":"box","use":true,"envVar":"TOKEN"}]"#).array
        let secret = try json(#"{"id":"other","allowRaw":true}"#)
        var use = CredentialPartDecision(); use.decision = "approve"
        #expect(throws: DiscoboxError.self) { try CredentialDecision.payload(request: request, secret: secret, held: held, use: use, delegate: .init()) }
        use.mode = "add"; use.delivery = "env"
        #expect(throws: DiscoboxError.self) { try use.fields(use: true, secret: secret) }
        use.mode = "replace"
        #expect(try use.fields(use: true, secret: secret)["raw"] == .string("env"))
        #expect(try use.fields(use: false, secret: secret)["raw"] == .null)
    }
}
