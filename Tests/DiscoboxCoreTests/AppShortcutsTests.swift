import Testing
import Foundation
@testable import DiscoboxCore

@Test func appShortcutDefaultsAndAliases() throws {
    let shortcuts = AppShortcuts()
    #expect(shortcuts.validationError == nil)
    #expect(shortcuts[.newBox] == "cmd+n")
    #expect(shortcuts[.switchBox] == "cmd+k")
    #expect(AppShortcut("cmd+{") == AppShortcut("cmd+shift+["))
    #expect(AppShortcut("cmd+}") == AppShortcut("cmd+shift+]"))
    #expect(AppShortcut("n") == nil)
    #expect(AppShortcut("cmd+cmd+n") == nil)
}
@Test func appShortcutValidationAndPersistence() throws {
    var shortcuts = AppShortcuts()
    shortcuts[.newBox] = "cmd+k"
    #expect(shortcuts.validationError != nil)
    shortcuts[.newBox] = "cmd+option+n"
    shortcuts[.nextPane] = ""
    #expect(shortcuts.validationError == nil)
    let decoded = try JSONDecoder().decode(AppShortcuts.self, from: JSONEncoder().encode(shortcuts))
    #expect(decoded == shortcuts)
    #expect(decoded[.previousTab] == "cmd+shift+[")
    shortcuts[.newBox] = "cmd+v"
    #expect(shortcuts.validationError != nil)
}
