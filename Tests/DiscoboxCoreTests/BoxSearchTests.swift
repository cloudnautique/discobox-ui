import Testing
import Foundation
@testable import DiscoboxCore

@Test func boxSearchIncludesHarnessRepositoryAndMultipleTerms() throws {
    let box = try JSONDecoder().decode(Sandbox.self, from: Data(#"{"id":"box-1","projectId":"p","displayName":"Assess integration","config":{"model":"codex","source":{"url":"https://github.com/example/widgets.git"}},"harnessConfig":{"name":"Codex (work)"},"runtime":{"state":"ready"}}"#.utf8))
    #expect(box.matchesSearch("CODEX"))
    #expect(box.matchesSearch("example/widgets"))
    #expect(box.matchesSearch("widgets codex"))
    #expect(box.matchesSearch("  assess  "))
    #expect(!box.matchesSearch("widgets claude"))
    #expect(box.matchesSearch(" "))
}
