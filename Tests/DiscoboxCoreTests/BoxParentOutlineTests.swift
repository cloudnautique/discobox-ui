import Foundation
import Testing
@testable import DiscoboxCore

private func item(_ id: String, parent: String? = nil, host: String = "ultra", project: String = "p",
                  attention: Bool = false) throws -> ConnectedBox {
    var json: [String: Any] = ["id": id, "projectId": project, "displayName": id,
                               "config": ["source": ["url": "https://example.com/" + id]],
                               "runtime": ["state": "ready"]]
    json["parentSandboxId"] = parent
    let box = try JSONDecoder().decode(Sandbox.self, from: JSONSerialization.data(withJSONObject: json))
    return ConnectedBox(location: .init(connection: host, box: id), computer: host, box: box, needsAttention: attention)
}

@Test func parentGroupsSpanRepositoriesAndRespectHostProjectAndFilters() throws {
    let lead = try item("lead"), child = try item("a", parent: "lead"), grandchild = try item("b", parent: "a", attention: true)
    let remote = try item("a", parent: "lead", host: "laptop"), otherProject = try item("c", parent: "lead", project: "other")
    let items = [child, remote, grandchild, otherProject, lead]
    let outline = BoxParentOutline(items)
    let rows = outline.visibleRows(collapsed: [])
    #expect(rows.map(\.id) == [remote, otherProject, lead, child, grandchild].map(\.location))
    #expect(rows.map(\.depth) == [0, 0, 0, 1, 2])
    #expect(outline.ancestors(of: grandchild.id) == [lead.id, child.id])
    let collapsed = outline.visibleRows(collapsed: [lead.id])
    #expect(collapsed.map(\.id) == [remote.id, otherProject.id, lead.id])
    #expect(collapsed.last?.attentionBelow == 1)
    let filtered = BoxParentOutline(items.filter { $0.id != lead.id })
    #expect(filtered.ancestors(of: grandchild.id) == [child.id])
}

@Test func malformedParentCyclesKeepEveryBoxReachable() throws {
    let items = try [item("a", parent: "b"), item("b", parent: "a"), item("c", parent: "b"), item("d", parent: "d")]
    let outline = BoxParentOutline(items)
    #expect(outline.visibleRows(collapsed: []).map(\.id) == items.map(\.id))
    #expect(outline.ancestors(of: items[2].id) == [items[0].id, items[1].id])
    #expect(outline.ancestors(of: items[3].id).isEmpty)
}

@Test func liveParentUpdatesReplaceListedParentAndSupportRelease() throws {
    let child = try item("child", parent: "original").box
    var eventData = ["projectId": "p", "sandboxId": "child", "name": "Child", "state": "ready",
                     "displayState": "running", "createdBySandboxId": "original", "parentSandboxId": "new-lead"]
    func apply() throws -> Sandbox {
        let event = try JSONDecoder().decode(ProjectBoxEvent.self, from: JSONSerialization.data(withJSONObject: eventData))
        return event.applying(to: child)
    }
    #expect(try apply().parentSandboxId == "new-lead")
    eventData.removeValue(forKey: "parentSandboxId")
    #expect(try apply().parentSandboxId == nil)
}
