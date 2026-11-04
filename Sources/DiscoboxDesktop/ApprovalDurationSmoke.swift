import AppKit
import SwiftUI
import DiscoboxCore

/// Exercises the real form against a capped offline server. No credentials,
/// Notification Center access, or external backend operations are involved.
@MainActor enum ApprovalDurationSmoke {
    static func verify() async throws {
        for mode in ["automatic", "too-long", "shorter", "deny", "external"] {
            let client = CappedApprovalClient(), workspace = Workspace()
            await workspace.connect(client: client, label: "Capped fixture", demo: true)
            await workspace.refreshApprovals()
            guard let item = workspace.approvals.first else { throw DiscoboxError("Approval fixture missing") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let initial: String? = mode == "too-long" ? "7200" : mode == "shorter" ? "900" : nil
            window.contentView = NSHostingView(rootView: ApprovalSheet(item: item, initialDuration: initial).environment(workspace))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); workspace.disconnect() }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func buttons() -> (approve: NSButton, deny: NSButton)? {
                guard let root = window.contentView else { return nil }
                let all = views(root).compactMap { $0 as? NSButton }
                guard let deny = all.first(where: { $0.cell === window.defaultButtonCell }) else { return nil }
                let y = deny.convert(deny.bounds, to: root).midY
                guard let approve = all.first(where: {
                    $0 !== deny && $0.keyEquivalent.isEmpty && $0.enclosingScrollView == nil &&
                    abs($0.convert($0.bounds, to: root).midY - y) < 2
                }) else { return nil }
                return (approve, deny)
            }
            if mode == "external" {
                await client.resolve()
                await workspace.refreshApprovals()
                try await wait {
                    let controls = views(window.contentView!).compactMap { $0 as? NSButton }
                    return controls.count == 1 && controls[0].keyEquivalent == "\r" && controls[0].isEnabled
                }
                guard await client.answers.isEmpty else { throw DiscoboxError("Externally resolved approval sent another response") }
                continue
            }
            try await wait { buttons() != nil }
            if mode == "too-long" {
                try await wait { buttons()?.approve.isEnabled == false }
                guard buttons()?.deny.isEnabled == true, await client.answers.isEmpty else {
                    throw DiscoboxError("Invalid duration disabled Deny or sent an approval")
                }
            } else { try await wait { buttons()?.approve.isEnabled == true } }
            if mode == "deny" || mode == "too-long" { buttons()!.deny.performClick(nil) }
            else { buttons()!.approve.performClick(nil) }
            try await wait { workspace.approvals.isEmpty }
            guard let answer = await client.answers.first else { throw DiscoboxError("Approval form sent no answer") }
            if mode == "deny" || mode == "too-long" {
                guard answer.action == "deny", await client.granted == nil else { throw DiscoboxError("Default approval button did not deny") }
            } else {
                let expected: Double = mode == "automatic" ? 1800 : 900
                guard answer.action == "approve", await client.granted == expected,
                      answer.payload?["secretMaxGrantTTLSeconds"] == .null else { throw DiscoboxError("Approval exceeded the credential limit or changed it") }
                if mode == "automatic", answer.payload?["grantTTLSeconds"] != .null { throw DiscoboxError("Automatic form explicitly sent a duration") }
            }
        }
        print("APPROVAL_RESOLUTION_SMOKE_OK: externally resolved requests show an enabled Done action, no stale form or duplicate response")
        print("APPROVAL_DURATION_SMOKE_OK: automatic 2-hour request capped to 30 minutes, over-limit custom duration blocks approval, shorter duration preserved, Deny remains default")
    }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw DiscoboxError("Approval duration UI check timed out at line \(line)")
    }
}

private actor CappedApprovalClient: DiscoboxClient {
    private let demo = DemoClient()
    private var pending = true
    private(set) var answers: [BridgeRequest] = []
    private(set) var granted: Double?
    func resolve() { pending = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
        switch request.operation {
        case .approvals:
            return Data((pending ? #"{"approvalRequests":[{"kind":"credential","credential":{"id":"capped","sandboxId":"demo-ui","status":"pending","name":"Repository","wellKnownId":"fixture.repository","grantTTLSeconds":7200,"policy":{"resolved":{"repo":"example/project"}}}}]}"# : #"{"approvalRequests":[]}"#).utf8)
        case .secrets:
            return Data(#"{"secrets":[{"id":"fixture-secret","name":"Repository","wellKnownId":"fixture.repository","maxGrantTTLSeconds":1800}]}"#.utf8)
        case .answer:
            if request.action == "approve" {
                let named = request.payload?["grantTTLSeconds"].number
                if let named, named == 0 || named > 1800 { throw DiscoboxError("Fixture: grant exceeds 30-minute cap") }
                granted = named ?? 1800
            }
            answers.append(request); pending = false
            return Data("{}".utf8)
        default: return try await demo.perform(request)
        }
    }
}
