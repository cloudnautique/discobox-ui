import AppKit
import SwiftUI
import DiscoboxCore

/// Actual sidebar controls and request presentation, with injected metadata.
/// No live hosts, terminal renderer, credentials, or system notifications.
@MainActor enum AgentActivitySmoke {
    static func run() async {
        do {
            try await verify()
            print("AGENT_ACTIVITY_SMOKE_OK: native quick filters toggle, counts stay scoped, selected box survives work completion, row Review opens the correct inbox; light/dark layouts captured")
            fflush(stdout); exit(0)
        } catch { print("AGENT_ACTIVITY_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func verify() async throws {
        let hub = Connections(polling: false), client = ActivityDesktopFixture()
        let host = try await hub.connect(.localComputer(name: "Studio"), demo: true) { client }
        await host.workspace.refreshApprovals()
        await hub.selectBox(.init(connection: host.id, box: "work"))
        let suite = "ai.discobox.smoke.activity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { hub.disconnectAll(); defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 370, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ActivitySmokeHost(hub: hub, defaults: defaults).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await wait { filterButtons(window).count == 2 }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            try capture(window, name: "activity-sidebar-" + name)
        }
        filterButtons(window)[0].performClick(nil)
        try await wait { hub.browser.activityFilter == .needsYou && hub.browserBoxes.count == 3 }
        guard hub.browserSelectionPin?.box.id == "work" else { throw DiscoboxError("Activity filter lost the current box") }
        try capture(window, name: "activity-needs-you")
        filterButtons(window)[1].performClick(nil)
        try await wait { hub.browser.activityFilter == .working && hub.browserBoxes.count == 1 }
        await client.finish(); await host.workspace.refresh()
        try await wait { hub.browserBoxes.isEmpty && hub.browserSelectionPin?.box.id == "work" }
        guard host.workspace.sandboxID == "work" else { throw DiscoboxError("Completing work changed selection") }
        filterButtons(window)[1].performClick(nil)
        try await wait { hub.browser.activityFilter == nil && hub.browserBoxes.count == 7 }
        // A single real row has one native action: Review. It must open this
        // host's two requests without answering either of them.
        guard let box = host.workspace.sandboxes.first(where: { $0.id == "approval" }) else { throw DiscoboxError("Approval fixture missing") }
        let review = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        review.contentView = NSHostingView(rootView: BoxRow(box: box).padding(12).frame(width: 380).environment(host.workspace))
        review.makeKeyAndOrderFront(nil)
        defer { review.orderOut(nil) }
        try await wait { buttons(review).count == 1 && buttons(review)[0].isEnabled }
        buttons(review)[0].performClick(nil)
        try await wait { review.attachedSheet?.defaultButtonCell != nil }
        guard host.workspace.approvals.count == 2, await client.writes == 0 else { throw DiscoboxError("Review sent an answer or used another inbox") }
        if let sheet = review.attachedSheet { review.endSheet(sheet) }
        // Open on a row from another computer must activate that computer and
        // its agent without changing the computer filter or the original box.
        let remote = try await hub.connect(.init(name: "Build server", endpoint: "https://activity.example.invalid"), demo: true, select: false) { ActivityDesktopFixture() }
        hub.browser.computerID = host.id
        guard let question = remote.workspace.sandboxes.first(where: { $0.id == "question" }) else { throw DiscoboxError("Question fixture missing") }
        let commands = WorkspaceCommands(defaults: defaults)
        let open = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        open.contentView = NSHostingView(rootView: BoxRow(box: question).padding(12).frame(width: 380)
            .environment(remote.workspace).environment(hub).environment(commands))
        open.makeKeyAndOrderFront(nil)
        defer { open.orderOut(nil) }
        try await wait { buttons(open).count == 1 && buttons(open)[0].isEnabled }
        buttons(open)[0].performClick(nil)
        try await wait { hub.active === remote && remote.workspace.sandboxID == "question" }
        guard hub.browser.computerID == host.id, host.workspace.sandboxID == "work", commands.currentLayout?.selected == "agent" else {
            throw DiscoboxError("Open retargeted the box/filter or failed to focus the remote agent")
        }
    }
    private static func filterButtons(_ window: NSWindow) -> [NSButton] {
        guard let root = window.contentView else { return [] }
        return buttons(window).filter {
            let rect = $0.convert($0.bounds, to: root)
            let top = root.isFlipped ? rect.midY - root.bounds.minY : root.bounds.maxY - rect.midY
            return top < 50 && top > 5
        }.sorted { $0.convert($0.bounds, to: root).midX < $1.convert($1.bounds, to: root).midX }
    }
    private static func buttons(_ window: NSWindow) -> [NSButton] { window.contentView.map { views($0).compactMap { $0 as? NSButton } } ?? [] }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Agent activity native check timed out at line \(line)")
    }
    private static func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let root = window.contentView,
              let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }
}

private struct ActivitySmokeHost: View {
    let hub: Connections
    @State private var runtimes = ConnectionRuntimes()
    @State private var commands: WorkspaceCommands
    init(hub: Connections, defaults: UserDefaults) {
        self.hub = hub
        _commands = State(initialValue: WorkspaceCommands(defaults: defaults))
    }
    var body: some View {
        let candidates = hub.browserCandidates
        VStack(spacing: 0) {
            BoxActivityFilters(selection: Binding(get: { hub.browser.activityFilter }, set: { hub.browser.activityFilter = $0 }),
                needsYou: candidates.filter(\.needsAttention).count, working: candidates.filter { $0.activity?.isWorking == true }.count).padding(14)
            Divider()
            ComputersSidebar(grouping: "repository", tagKey: "")
        }.background(DiscoboxAppearance.sidebar)
            .environment(hub).environment(hub.active.workspace).environment(runtimes).environment(commands)
    }
}

private actor ActivityDesktopFixture: DiscoboxClient {
    let demo = DemoClient()
    private var finished = false
    private(set) var writes = 0
    func finish() { finished = true }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .execs { return Data(#"{"execs":[]}"#.utf8) }
        if request.operation == .services { return Data(#"{"services":[]}"#.utf8) }
        if request.operation == .sandboxes {
            let definitions = [("work", "Review webhook delivery", finished ? "done" : "working", "", "api"),
                ("approval", "Audit authorization rules", "idle", "", "api"),
                ("question", "Reconcile billing records", "blocked", "question", "api"),
                ("done", "Update onboarding copy", "done", "", "website"),
                ("idle", "Refresh landing page", "idle", "", "website"),
                ("failed", "Fix checkout regression", "error", "", "website"),
                ("stopped", "Explore navigation redesign", "idle", "", "website")]
            let boxes: [JSONValue] = definitions.map { id, title, state, kind, repo in
                .object(["id": .string(id), "projectId": .string("demo"), "displayName": .string(title), "config": .object(["name": .string(title), "model": .string("Codex")]),
                    "meta": .object(["tags": .object(["repository": .string("acme/" + repo), "branch": .string("main")])]),
                    "runtime": .object(["state": .string("ready"), "runtimeState": .string(id == "stopped" ? "stopped" : "running"), "agentStatus": .object([
                        "observedAt": .string(Date().ISO8601Format()), "sessions": .array([.object(["primary": .bool(true), "execStatus": .string("running"), "title": .string(title),
                            "programStatus": .object(["state": .string(state), "kind": .string(kind), "msg": .string(state == "working" ? "Running the test suite" : state == "blocked" ? "Which customer should be kept?" : "")])])])
                    ])])])
            }
            return try JSONEncoder().encode(JSONValue.object(["sandboxes": .array(boxes)]))
        }
        if request.operation == .approvals {
            let items: [JSONValue] = ["first", "second"].map { .object(["kind": .string("credential"), "credential": .object([
                "id": .string($0), "sandboxId": .string("approval"), "status": .string("pending"), "name": .string("Repository access"), "use": .object([:])
            ])]) }
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(items)]))
        }
        if request.operation == .answer { writes += 1; throw DiscoboxError("No approval writes permitted in this UI check") }
        return try await demo.perform(request)
    }
}
