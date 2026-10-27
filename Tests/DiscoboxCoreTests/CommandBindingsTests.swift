import Foundation
import Testing
@testable import DiscoboxCore

@Test func defaultLeaderPreservesTerminalKeysAndRoutesCommands() {
    let bindings = CommandBindings()
    #expect(bindings.validationError == nil)
    var router = LeaderRouter()
    #expect(router.key("ctrl+c", bindings: bindings) == .pass)
    #expect(router.key("s", bindings: bindings) == .pass)
    #expect(router.key("ctrl+a", bindings: bindings) == .pending)
    #expect(router.key("s", bindings: bindings) == .command(.newShell))
    #expect(router.key("ctrl+a", bindings: bindings) == .pending)
    #expect(router.key("S", bindings: bindings) == .pending)
    #expect(router.key("0", bindings: bindings) == .command(.services))
    #expect(router.key("ctrl+a", bindings: bindings) == .pending)
    #expect(router.key("ctrl+a", bindings: bindings) == .literal("\u{1}"))
}

@Test func remappedLeaderDoesNotLeakEOFAndRestoresLiteralKeys() {
    var bindings = CommandBindings(leader: "ctrl+d")
    bindings[.newShell] = "n"
    var router = LeaderRouter()
    #expect(router.key("ctrl+a", bindings: bindings) == .pass)
    #expect(router.key("ctrl+d", bindings: bindings) == .pending)
    #expect(router.key("n", bindings: bindings) == .command(.newShell))
    #expect(router.key("ctrl+d", bindings: bindings) == .pending)
    #expect(router.key("ctrl+d", bindings: bindings) == .literal("\u{4}"))
    #expect(router.key("ctrl+d", bindings: bindings) == .pending)
    #expect(router.key("escape", bindings: bindings) == .cancelled)
    #expect(router.key("n", bindings: bindings) == .pass)
    #expect(router.key("ctrl+d", bindings: bindings) == .pending)
    #expect(router.key("A", bindings: bindings) == .command(.audit))
    #expect(router.key("x", bindings: bindings) == .pass)
}

@Test func bindingConflictsPrefixesAndPersistence() throws {
    var bindings = CommandBindings()
    bindings[.newShell] = "S"
    #expect(bindings.validationError != nil)
    bindings[.newShell] = "a"
    #expect(bindings.validationError != nil)
    bindings[.newShell] = "2"
    #expect(bindings.validationError != nil)
    bindings[.newShell] = "escape"
    #expect(bindings.validationError != nil)
    bindings[.newShell] = ""
    #expect(bindings.validationError == nil)
    bindings.leader = "ctrl+d"
    let roundtrip = try JSONDecoder().decode(CommandBindings.self, from: JSONEncoder().encode(bindings))
    #expect(roundtrip == bindings)
    #expect(roundtrip[.newShell].isEmpty)
    var router = LeaderRouter()
    #expect(router.key("ctrl+d", bindings: roundtrip) == .pending)
    router.cancel()
    #expect(router.key("s", bindings: roundtrip) == .pass)
    #expect(router.key("ctrl+d", bindings: roundtrip) == .pending)
    #expect(router.key("2", bindings: roundtrip) == .terminal(2))
}
