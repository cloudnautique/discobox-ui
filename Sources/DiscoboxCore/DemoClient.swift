import Foundation

/// Self-contained fixture data. Demo never opens a socket or starts a process.
public actor DemoClient: DiscoboxClient {
    private var boxOverrides: [String: [String: Any]] = [:]
    private var purgedBoxes: Set<String> = []
    private var closedShells: Set<String> = []
    private var newBoxes: [[String: Any]] = []
    private var messages: [String] = []
    public private(set) var lastApprovalAction: String?
    private var pendingRequests: Bool
    public init(pendingRequests: Bool = false) { self.pendingRequests = pendingRequests }

    public func setPendingRequests(_ pending: Bool) { pendingRequests = pending }

    public func perform(_ request: BridgeRequest) async throws -> Data {
        switch request.operation {
        case .boxAction:
            let list = try JSONSerialization.jsonObject(with: Data(Self.boxes.utf8)) as! [String: Any]
            let all = (list["sandboxes"] as! [[String: Any]]) + newBoxes
            guard let id = request.sandboxID, var box = boxOverrides[id] ?? all.first(where: { $0["id"] as? String == id }) else { throw DiscoboxError("Box not found") }
            switch request.action {
            case "purge": purgedBoxes.insert(id)
            case "rename": box["displayName"] = request.prompt
            case "archive": box["runtime"] = ["state": "archived", "displayState": "archived"]
            case "stop", "unarchive": box["runtime"] = ["state": "ready", "runtimeState": "stopped"]
            default: box["runtime"] = ["state": "ready", "runtimeState": "running"]
            }
            boxOverrides[id] = box
            return Data("{}".utf8)
        case .usageHeaders: return Data(#"{"headers":{}}"#.utf8)
        case .usage:
            return try JSONSerialization.data(withJSONObject: ["records": [["id": "demo-quota", "poolId": "local", "sandboxId": "demo-ui", "createdAt": "2026-10-27T17:00:00Z", "provider": "codex"]], "missing": []])
        case .auditBody where request.requestID == "demo-quota":
            return try JSONSerialization.data(withJSONObject: ["text": #"{"rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":18000,"reset_at":1793124000},"secondary_window":{"used_percent":30,"limit_window_seconds":604800}}}"#, "truncated": false])
        case .auditBody: return Data(#"{"text":"Offline response"}"#.utf8)
        case .files: return Data(#"{"path":"/workspace","entries":[]}"#.utf8)
        case .upload, .download: throw DiscoboxError("File transfer is unavailable in the offline demo.")
        case .tools: return Data(#"{"tools":[]}"#.utf8)
        case .openTool, .newAgent: throw DiscoboxError("Tool execution is unavailable in the offline demo.")
        case .approvals:
            return Data((pendingRequests ? #"{"approvalRequests":[{"kind":"credential","credential":{"id":"demo-request","sandboxId":"demo-ui","status":"pending","name":"GitHub","hosts":["api.github.com"],"grantTTLSeconds":3600,"justification":"Read repository issues to investigate a reported bug.","policy":{"statements":[{"effect":"allow","actions":["read"],"resource":{"type":"issue"}}],"resolved":{"primary.repo":"example/project"}}}}]}"# : #"{"approvalRequests":[]}"#).utf8)
        case .secrets: return Data(#"{"secrets":[{"id":"demo-token","name":"GitHub token","host":"api.github.com","maxGrantTTLSeconds":28800}]}"#.utf8)
        case .answer: lastApprovalAction = request.action; pendingRequests = false; return Data("{}".utf8)
        case .deleteSecret: return Data("{}".utf8)
        case .createSecret: return Data(#"{"id":"demo-token"}"#.utf8)
        case .ruleProposals: return Data("{}".utf8)
        case .harnesses:
            return Data(#"{"harnessConfigs":[{"id":"demo-harness","name":"Demo agent","configured":true}]}"#.utf8)
        case .createBox:
            let list = try JSONSerialization.jsonObject(with: Data(Self.boxes.utf8)) as! [String: Any]
            var box = (list["sandboxes"] as! [[String: Any]])[0]
            box["id"] = "demo-" + UUID().uuidString
            box["displayName"] = "New demo box"
            newBoxes.append(box)
            return try JSONSerialization.data(withJSONObject: box)
        case .closeShell, .closeTerminal:
            if let id = request.execID { closedShells.insert(id) }
            return Data("{}".utf8)
        case .audit:
            return Data(#"{"records":[{"id":"demo-hook","source":"Hooks","order":1,"time":"2026-10-26T14:00:00Z","summary":"Agent started a task","detail":"{\"event\": \"task.started\"}"},{"id":"demo-http","source":"HTTP","order":2,"time":"2026-10-26T14:00:01Z","summary":"GET 200 api.example.test","detail":"{\"method\": \"GET\", \"statusCode\": 200}"}],"missing":[],"limited":[]}"#.utf8)
        case .defaultProject:
            return Data(#"{"id":"demo","name":"Personal workspace","default":true}"#.utf8)
        case .sandboxes:
            var list = try JSONSerialization.jsonObject(with: Data(Self.boxes.utf8)) as! [String: Any]
            list["sandboxes"] = ((list["sandboxes"] as! [[String: Any]]) + newBoxes).filter { !purgedBoxes.contains($0["id"] as! String) }.map { boxOverrides[$0["id"] as! String] ?? $0 }
            return try JSONSerialization.data(withJSONObject: list)
        case .execs:
            let stopped = request.sandboxID == "demo-api"
            let rows: [[String: Any]] = [
                ["id":"agent-1", "status": stopped ? "exited" : "running", "command":["bash"],
                 "startupCommand":["claude"], "workdir":"/workspace/discobox", "tty":true, "primary":true],
                ["id":"shell-1", "status":stopped ? "exited" : "running", "command":["bash"],
                 "workdir":"/workspace/discobox", "tty":true]
            ]
            return try JSONSerialization.data(withJSONObject: ["execs": rows.filter { !closedShells.contains($0["id"] as! String) }])
        case .services:
            return Data(#"{"services":[{"id":"web","name":"Development server","description":"Vite preview","status":"running","ports":[5173]},{"id":"api","name":"API","description":"Local application API","status":"running","ports":[8080]}]}"#.utf8)
        case .screen:
            let lines = request.execID == "shell-1"
                ? ["discobox /workspace/discobox", "", "$ git status", "On branch feature/native-workspace", "nothing to commit, working tree clean", "", "$ "]
                : ["╭─ Claude Code ───────────────────────────────────────╮", "│ /workspace/discobox                                │", "╰────────────────────────────────────────────────────╯", "", "❯ Build a native workspace for our existing boxes.", "", "● I’ve reviewed the API and the client boundaries.", "  Existing boxes remain available from every client.", "", "  ✓ Project and box navigation", "  ✓ Services and terminal inspection", "  ✓ Read-only by default", "", "Ready for your next message.", ""]
            return try JSONSerialization.data(withJSONObject: [
                "rows":24, "cols":100, "lines":lines + messages, "scrollback":[],
                "title":"Native workspace", "exited": request.sandboxID == "demo-api"
            ])
        case .newShell:
            closedShells.remove("shell-1")
            return Data(#"{"id":"shell-1","status":"running","command":["bash"],"workdir":"/workspace/discobox","tty":true}"#.utf8)
        case .input:
            for part in request.input ?? [] { if let text = part.text { messages.append("❯ " + text) } }
            messages.append("[Demo only — no command was executed]")
            return Data(#"{"resumeAfter":"demo"}"#.utf8)
        }
    }

    private static let boxes = #"""
    {"sandboxes":[
      {"id":"demo-ui","projectId":"demo","displayName":"Native macOS workspace","config":{"name":"discobox-ui","model":"claude-sonnet","harnessConfigId":"demo-harness"},"runtime":{"state":"ready","runtimeState":"running"},"meta":{"description":"A focused desktop experience for your coding agents.","tags":{"repository":"discobox-ui","branch":"feature/native-workspace"}},"poolId":"local","platform":"linux/arm64"},
      {"id":"demo-api","projectId":"demo","displayName":"Review API pagination","config":{"name":"discobox"},"runtime":{"state":"ready","runtimeState":"stopped"},"meta":{"description":"Inspect the last terminal screen without waking the box.","tags":{"repository":"discobox"}},"poolId":"local","platform":"linux/arm64"},
      {"id":"demo-tests","projectId":"demo","displayName":"Investigate integration tests","config":{"name":"discobox"},"runtime":{"state":"failed","errorMessage":"Source delivery needs attention."},"meta":{"tags":{"repository":"discobox"}},"poolId":"remote"}
    ]}
    """#
}
