import Foundation
import Testing
@testable import DiscoboxCore

struct PoolProxyDraftTests {
    @Test func defaultResetIsNullAndExplicitProxyPreservesStoredAuthentication() throws {
        var draft = PoolProxyDraft(proxy: .null)
        #expect(try draft.payload() == .null)
        draft.defaults = false; draft.mode = "explicit"; draft.http = "https://proxy.test:8443"
        #expect(try draft.payload()["http"] == .string("https://proxy.test:8443"))
        #expect(try draft.payload()["clearHttpCredentials"] == .null)
        draft.httpCredentials = "name:p@ss:word"
        let url = try draft.payload()["http"].string
        #expect(URLComponents(string: url)?.user == "name")
        #expect(URLComponents(string: url)?.password == "p@ss:word")
        #expect(URLComponents(string: url)?.host == "proxy.test")
        draft.clearHTTP = true
        #expect(throws: DiscoboxError.self) { try draft.payload() }
        draft.httpCredentials = ""
        #expect(try draft.payload()["clearHttpCredentials"] == .bool(true))
        draft.http = "https://name:password@proxy.test"
        #expect(throws: DiscoboxError.self) { try draft.payload() }
    }
}
