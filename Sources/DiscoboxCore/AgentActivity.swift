import Foundation

/// Presentation of reported activity, never inferred from terminal output.
public struct AgentActivity: Equatable, Sendable {
    public enum State: String, Sendable {
        case working, idle, finished, approval, question, signIn, blocked, failed, unavailable, inactive
    }
    public let state: State
    public let label: String
    public let message: String
    public let approvalCount: Int
    public var needsYou: Bool { [.approval, .question, .signIn, .blocked, .failed].contains(state) }
    public var isWorking: Bool { state == .working }
    public var symbol: String {
        switch state {
        case .working: "waveform.path"
        case .approval: "hand.raised"
        case .question: "bubble.left.and.bubble.right"
        case .signIn: "key"
        case .blocked: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        case .finished: "checkmark.circle"
        case .idle: "minus.circle"
        case .inactive: "power"
        case .unavailable: "questionmark.circle"
        }
    }
    public init(box: Sandbox, pendingRequests: Int = 0, reachable: Bool = true, now: Date = .now) {
        approvalCount = max(0, pendingRequests)
        guard reachable else {
            state = .unavailable; label = "Status unavailable"; message = "Connection interrupted"; return
        }
        if pendingRequests > 0 {
            state = .approval; label = "Needs approval"; message = ""; return
        }
        guard !box.isArchived, box.runtime.runtimeState == "running" || box.isRunning else {
            state = .inactive; label = box.status; message = ""; return
        }
        let status = box.runtime.agentStatus ?? .null
        // The pool normally posts every 15 seconds. Expire the containing
        // snapshot after a generous two minutes, not the program's reportedAt:
        // an unchanged Idle/Working report can legitimately be much older.
        let observedText = status["observedAt"].string
        if !observedText.isEmpty {
            guard let observed = Self.date(observedText), abs(now.timeIntervalSince(observed)) <= 120 else {
                state = .unavailable; label = "Status unavailable"; message = "Activity report is out of date"; return
            }
        }
        let session = Self.primarySession(status)
        let process = session["execStatus"].string
        let report = session["programStatus"]
        let completed = ["done", "error"].contains(report["state"].string) && ["exited", "failed"].contains(process)
        guard process.isEmpty || process == "running" || completed, session["observedAt"] == .null else {
            state = .unavailable; label = "Activity unavailable"; message = "Terminal is not running"; return
        }
        message = Self.text(report["msg"].string, limit: 240)
        switch report["state"].string {
        case "working": state = .working; label = "Working"
        case "idle": state = .idle; label = "Idle"
        case "done": state = .finished; label = "Finished"
        case "error": state = .failed; label = "Agent failed"
        case "blocked":
            switch report["kind"].string {
            case "permission": state = .approval; label = "Needs approval"
            case "question": state = .question; label = "Needs an answer"
            case "auth": state = .signIn; label = "Needs sign-in"
            default: state = .blocked; label = "Needs input"
            }
        default: state = .unavailable; label = "Activity unavailable"
        }
    }
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    static func date(_ value: String) -> Date? { (try? fractional.parse(value)) ?? (try? whole.parse(value)) }
    static func primarySession(_ status: JSONValue) -> JSONValue {
        var latest: JSONValue = .null, started = Date.distantPast
        for session in status["sessions"].array where session["primary"] == .bool(true) {
            let time = date(session["startedAt"].string) ?? .distantPast
            if latest == .null || time > started { latest = session; started = time }
        }
        return latest
    }
    static func text(_ value: String, limit: Int = 512) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit).description
    }
}

public enum BoxActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case needsYou, working
    public var id: Self { self }
    public var title: String { self == .needsYou ? "Needs you" : "Working" }
    public func matches(_ activity: AgentActivity, box: Sandbox) -> Bool {
        self == .working ? activity.isWorking : activity.needsYou || box.matchesAttention
    }
}

public extension Sandbox {
    /// Use the title fields, not a colon split of a user-defined name. Remove
    /// only the exact status-message suffix the server itself appended.
    var sidebarTitle: String {
        if let name = meta?.name, !AgentActivity.text(name).isEmpty { return AgentActivity.text(name) }
        let session = AgentActivity.primarySession(runtime.agentStatus ?? .null)
        let terminal = AgentActivity.text(session["title"].string)
        if !terminal.isEmpty { return terminal }
        let message = AgentActivity.text(session["programStatus"]["msg"].string, limit: 2048)
        let suffix = ": " + message
        if !message.isEmpty, displayName.hasSuffix(suffix) {
            let title = String(displayName.dropLast(suffix.count))
            if !title.isEmpty { return title }
        }
        return AgentActivity.text(displayName)
    }
}

public extension Workspace {
    func activity(for box: Sandbox) -> AgentActivity {
        AgentActivity(box: box, pendingRequests: approvals.filter { $0.boxID == box.id }.count,
                      reachable: isConnected && connectionError == nil, now: activityObservationTime)
    }
}
