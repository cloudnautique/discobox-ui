import Foundation
import Testing
@testable import DiscoboxCore

@Test func tagFiltersSupportPresenceExactValuesAndMultiSelection() {
    let tags = ["review": "", "team": "platform", "ticket": "ENG=12"]
    #expect(BoxOrganization.matches(tags: tags, selectors: [], matchAny: false))
    #expect(BoxOrganization.matches(tags: tags, selectors: ["review", "team=platform"], matchAny: false))
    #expect(BoxOrganization.matches(tags: tags, selectors: ["team", "ticket=ENG=12"], matchAny: false))
    #expect(!BoxOrganization.matches(tags: tags, selectors: ["review", "team=product"], matchAny: false))
    #expect(BoxOrganization.matches(tags: tags, selectors: ["review", "team=product"], matchAny: true))
    #expect(!BoxOrganization.matches(tags: [:], selectors: ["review"], matchAny: true))
    #expect(BoxOrganization.matches(tags: tags, selectors: ["review="], matchAny: false))
    #expect(!BoxOrganization.matches(tags: tags, selectors: ["team="], matchAny: false))
}

@Test func groupingKeepsMissingTagsAndPlainLabelsDistinct() async throws {
    let client = DemoClient()
    let response = try await client.decode(.init(.sandboxes), as: SandboxesResponse.self)
    let box = try #require(response.sandboxes?.first)
    #expect(BoxOrganization.group(box, by: "tag", tagKey: "team") == "Untagged")
    #expect(BoxOrganization.group(box, by: "tag", tagKey: "branch") == "feature/native-workspace")
    #expect(BoxOrganization.group(box, by: "state", tagKey: "") == box.status)
    #expect(BoxOrganization.group(box, by: "repository", tagKey: "") == box.repository)
}

@Test func inspectorShortcutDefaultsAndCustomizationsAreValidated() throws {
    var shortcuts = AppShortcuts()
    #expect(shortcuts[.toggleInspector] == "cmd+option+i")
    #expect(shortcuts.validationError == nil)
    shortcuts[.toggleInspector] = "cmd+k"
    #expect(shortcuts.validationError != nil)
    shortcuts[.toggleInspector] = "cmd+shift+i"
    let saved = try JSONDecoder().decode(AppShortcuts.self, from: JSONEncoder().encode(shortcuts))
    #expect(saved[.toggleInspector] == "cmd+shift+i")
}
