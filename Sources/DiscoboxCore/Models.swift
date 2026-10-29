import Foundation

public struct Project: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let `default`: Bool?
}

public struct Sandbox: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let projectId: String
    public let displayName: String
    public let config: Configuration
    public let runtime: Runtime
    public let meta: Metadata?
    public let poolId: String?
    public let platform: String?
    public let createdAt: String?
    public let harnessConfig: JSONValue?

    public struct Configuration: Codable, Sendable, Equatable {
        public let name: String?
        public let model: String?
        public let harnessConfigId: String?
        public let source: JSONValue?
    }
    public struct Runtime: Codable, Sendable, Equatable {
        public let state: String
        public let runtimeState: String?
        public let errorMessage: String?
        public let lastActiveAt: String?
        public let displayState: String?
        public let agentStatus: JSONValue?
    }
    public struct Metadata: Codable, Sendable, Equatable {
        public let name: String?
        public let description: String?
        public let tags: [String: String]?
    }
    public func matchesSearch(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        let fields = [displayName, id, repository ?? "", harnessName ?? "", config.model ?? "", branch ?? "", meta?.description ?? "", meta?.tags?.values.joined(separator: " ") ?? ""]
        return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
    }
    public var isRunning: Bool { runtime.displayState.map { $0 == "running" } ?? (runtime.state == "ready" && runtime.runtimeState == "running") }
    public var isArchived: Bool { ["archived", "deleted"].contains(runtime.displayState ?? runtime.state) }
    public var harnessName: String? { harnessConfig?["name"].string ?? config.model }
    public var repository: String? {
        guard let raw = config.source?["url"].string ?? config.source?["localDirectory"].string ?? meta?.tags?["repository"], !raw.isEmpty else { return nil }
        var value = raw
        if let url = URL(string: raw), url.host != nil { value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else if raw.hasPrefix("git@"), let colon = raw.firstIndex(of: ":") { value = String(raw[raw.index(after: colon)...]) }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value
    }
    public var branch: String? {
        runtime.agentStatus?["sources"].array.first(where: { $0["slug"].string == "primary" })?["branch"].string ?? meta?.tags?["branch"]
    }
    public var status: String {
        if let state = runtime.displayState { return state.capitalized }
        guard runtime.state == "ready" else { return runtime.state.replacingOccurrences(of: "_", with: " ").capitalized }
        return runtime.runtimeState?.capitalized ?? "Power unknown"
    }
    public var matchesAttention: Bool { ["failed", "error"].contains(runtime.displayState ?? runtime.state) || runtime.errorMessage?.isEmpty == false }
}

public struct Exec: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let command: [String]
    public let startupCommand: [String]?
    public let workdir: String
    public let tty: Bool
    public let primary: Bool?
    public let observedAt: String?
    public let metadata: [String: String]?
    public let currentHarnessId: String?
    public let harnessId: String?
    public var title: String {
        if primary == true { return "Agent" }
        if let tool = metadata?["tool"] { return tool == "ai.discobox.diff" ? "Changes" : tool }
        if !(harnessId?.isEmpty ?? true) || !(currentHarnessId?.isEmpty ?? true) { return "Agent" }
        return (startupCommand?.first ?? command.first).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Terminal"
    }
    public var isShell: Bool { primary != true && metadata?["tool"] == nil && tty && (harnessId?.isEmpty ?? true) && (currentHarnessId?.isEmpty ?? true) }
    public var acceptsInput: Bool { id != "primary" && status == "running" && observedAt == nil && tty }
}

public struct Service: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let status: String
    public let ports: [Int]?
    public let error: String?
    public let problem: String?
    public let observedAt: String?
}

public struct TerminalScreen: Codable, Sendable, Equatable {
    public let rows: Int
    public let cols: Int
    public let lines: [String]
    public let scrollback: [String]?
    public let title: String?
    public let observedAt: String?
    public let outputAt: String?
    public let exited: Bool
    public var text: String { ((scrollback ?? []) + lines).joined(separator: "\n") }
}

public struct SandboxesResponse: Decodable, Sendable { public let sandboxes: [Sandbox]? }
public struct ExecsResponse: Decodable, Sendable {
    public let execs: [Exec]
    public let observedAt: String?
}
public struct ServicesResponse: Decodable, Sendable {
    public let services: [Service]
    public let observedAt: String?
}

public struct InputPart: Codable, Sendable, Equatable {
    public let text: String?
    public let key: String?
    public static func text(_ value: String) -> Self { Self(text: value, key: nil) }
    public static func key(_ value: String) -> Self { Self(text: nil, key: value) }
}

public struct BridgeRequest: Encodable, Sendable {
    public enum Operation: String, Encodable, Sendable { case deleteSecret, usageHeaders, usage, boxAction, auditBody, files, upload, download, tools, openTool, newAgent, approvals, secrets, answer, createSecret, ruleProposals, defaultProject, sandboxes, execs, services, screen, input, newShell, closeShell, closeTerminal, createBox, harnesses, audit }
    public let operation: Operation
    public let projectID: String?
    public let sandboxID: String?
    public let execID: String?
    public let harnessID: String?
    public let repository: String?
    public let remotePath: String?
    public let localPath: String?
    public let prompt: String?
    public let requestID: String?
    public let kind: String?
    public let action: String?
    public let payload: JSONValue?
    public let input: [InputPart]?

    public init(_ operation: Operation, projectID: String? = nil, sandboxID: String? = nil,
                execID: String? = nil, input: [InputPart]? = nil, harnessID: String? = nil, repository: String? = nil, prompt: String? = nil, requestID: String? = nil, kind: String? = nil, action: String? = nil, payload: JSONValue? = nil, remotePath: String? = nil, localPath: String? = nil) {
 self.remotePath = remotePath; self.localPath = localPath
 self.prompt = prompt; self.requestID = requestID; self.kind = kind; self.action = action; self.payload = payload
        self.harnessID = harnessID
        self.repository = repository
        self.operation = operation
        self.projectID = projectID
        self.sandboxID = sandboxID
        self.execID = execID
        self.input = input
    }
}

public struct DiscoboxError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Harness: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let configured: Bool
}
public struct HarnessList: Decodable, Sendable { public let harnessConfigs: [Harness]? }
public struct AuditRecord: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let time: String
    public let order: Double
    public let summary: String
    public let detail: String
}
public struct AuditSnapshot: Decodable, Sendable {
    public let before: [String: String]?
    public let since: [String: String]?
    public let after: [String: String]?
    public let records: [AuditRecord]
    public let missing: [String]
    public let limited: [String]
}
