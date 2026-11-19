import Foundation

public struct Project: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let `default`: Bool?
    public let defaultPoolId: String?
    public let defaultHarnessConfigId: String?
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
    public let discoboxApi: Bool?
    private enum CodingKeys: String, CodingKey {
        case id, projectId, displayName, config, runtime, meta, poolId, platform, createdAt, harnessConfig, discoboxApi, preparationStatus
    }
    var projectProgram: ProjectBoxEvent.Program? = nil
    public var preparationStatus: String? = nil

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
        public let errorReason: String?
        public let lastActiveAt: String?
        public let displayState: String?
        public let stateReportedAt: String?
        public let agentStatus: JSONValue?
        public let resources: JSONValue?
        public let upgrade: Upgrade?
        /// Provisioned; `runtimeState` then says whether it is running.
        public var isReady: Bool { state == "ready" }
    }
    /// Only decode the stable upgrade fields; image and bundle metadata differ
    /// between server releases and must not prevent boxes from being listed.
    public struct Upgrade: Codable, Sendable, Equatable {
        public let available: Bool
        public let reason: String?
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
    /// The box's lifecycle as one value: the server's `displayState` when it
    /// reports one; otherwise `state`, refined by `runtimeState` once ready.
    public var lifecycle: BoxLifecycle {
        if let display = runtime.displayState { return BoxLifecycle(display) }
        return runtime.isReady ? BoxLifecycle(runtime.runtimeState ?? "") : BoxLifecycle(runtime.state)
    }
    public var isRunning: Bool { lifecycle == .running }
    public var isDeleted: Bool { lifecycle == .deleted || BoxLifecycle(runtime.state) == .deleted }
    public var isArchived: Bool { !isDeleted && lifecycle == .archived }
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
    public var matchesAttention: Bool { lifecycle == .failed || lifecycle == .error || runtime.errorMessage?.isEmpty == false }
}

/// Box lifecycle states the client acts on. Unknown or newer server values
/// are preserved, never coerced into a known state.
public enum BoxLifecycle: Equatable, Sendable {
    case running, stopped, starting, stopping, pending, archived, archiving, deleted, deleting, repairing, failed, error
    case unknown(String)
    public init(_ raw: String) {
        switch raw.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        case "starting": self = .starting
        case "stopping": self = .stopping
        case "pending": self = .pending
        case "archived": self = .archived
        case "archiving": self = .archiving
        case "deleted": self = .deleted
        case "deleting": self = .deleting
        case "repairing": self = .repairing
        case "failed": self = .failed
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }
    /// A transition in progress, during which lifecycle actions are refused.
    public var isTransitioning: Bool { [.starting, .stopping, .archiving, .deleting, .repairing].contains(self) }
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

/// The companion's bounded request contract. Operation names, permission
/// classes and `version` are published in Companion/protocol.json, which the
/// Go and Swift tests both check, so neither side can drift alone.
public struct BridgeRequest: Encodable, Sendable {
    public static let protocolVersion = 2
    public enum Operation: String, Encodable, Sendable, CaseIterable { case boxLink, serverPeer, setDefaultHarness, updateSecretLimits, harnessDetails, harnessChanges, saveHarnessChanges, discardHarnessChanges, poolConfiguration, updatePoolProxy, approvalContext, poolResources, clearPoolCache, deleteSecret, usageHeaders, usage, boxAction, auditBody, saveAuditBody, files, upload, download, tools, openTool, newAgent, approvals, secrets, answer, createSecret, defaultProject, sandboxes, execs, services, screen, newShell, closeShell, closeTerminal, createBox, harnesses, audit
        /// The companion flag this operation needs. It keeps a polling read
        /// from mutating by mistake; it is not a security boundary.
        public enum Permission: String, Sendable { case read, manage, shell }
        public var permission: Permission {
            switch self {
            case .newShell: .shell
            case .setDefaultHarness, .updateSecretLimits, .saveHarnessChanges, .discardHarnessChanges, .updatePoolProxy,
                 .clearPoolCache, .deleteSecret, .boxAction, .saveAuditBody, .upload, .download, .openTool, .newAgent,
                 .answer, .createSecret, .closeShell, .closeTerminal, .createBox: .manage
            case .boxLink, .serverPeer, .harnessDetails, .harnessChanges, .poolConfiguration, .approvalContext, .poolResources,
                 .usageHeaders, .usage, .auditBody, .files, .tools, .approvals, .secrets, .defaultProject, .sandboxes, .execs,
                 .services, .screen, .harnesses, .audit: .read
            }
        }
    }
    public struct UsagePage: Encodable, Sendable {
        let host: String
        let after: String?
        let limit: Int
    }
    public let usagePage: UsagePage?
    public let operation: Operation
    public let discoboxAPI: Bool?
    public let projectID: String?
    public let sandboxID: String?
    public let execID: String?
    public let harnessID: String?
    public let poolID: String?
    public let repository: String?
    public let remotePath: String?
    public let localPath: String?
    public let prompt: String?
    /// A box's new name (rename).
    public let name: String?
    /// An approval request; `kind` is that request's kind.
    public let requestID: String?
    public let kind: String?
    public let secretID: String?
    /// An audit/usage record within `poolID`.
    public let recordID: String?
    public let toolID: String?
    public let link: String?
    public let action: String?
    public let payload: JSONValue?

    public init(_ operation: Operation, projectID: String? = nil, sandboxID: String? = nil,
                execID: String? = nil, harnessID: String? = nil, repository: String? = nil, prompt: String? = nil, name: String? = nil, requestID: String? = nil, kind: String? = nil, secretID: String? = nil, recordID: String? = nil, toolID: String? = nil, link: String? = nil, action: String? = nil, payload: JSONValue? = nil, remotePath: String? = nil, localPath: String? = nil, poolID: String? = nil, discoboxAPI: Bool? = nil, usagePage: UsagePage? = nil) {
        self.usagePage = usagePage
        self.discoboxAPI = discoboxAPI
        self.name = name; self.secretID = secretID; self.recordID = recordID; self.toolID = toolID; self.link = link
        self.poolID = poolID
 self.remotePath = remotePath; self.localPath = localPath
 self.prompt = prompt; self.requestID = requestID; self.kind = kind; self.action = action; self.payload = payload
        self.harnessID = harnessID
        self.repository = repository
        self.operation = operation
        self.projectID = projectID
        self.sandboxID = sandboxID
        self.execID = execID
    }
}

public struct DiscoboxError: LocalizedError, Sendable {
    /// What went wrong, for decisions; `message` is only for people. The
    /// companion classifies at its boundary (`errorKind`); Swift never infers
    /// a kind from message text.
    public enum Kind: String, Sendable {
        /// The network or transport failed; reads may be retried.
        case transport
        /// Authentication or enrollment was refused (HTTP 401/403).
        case unauthorized
        /// TLS verification failed; retrying cannot help.
        case certificate
        case other
        /// Unknown kinds from a newer companion are treated as `other`.
        init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .other }
    }
    public let message: String
    let httpStatus: Int?
    public let kind: Kind
    public var connectionRetryable: Bool { kind == .transport }
    public init(_ message: String, kind: Kind = .other, httpStatus: Int? = nil) { self.message = message; self.kind = kind; self.httpStatus = httpStatus }
    public init(_ message: String, connectionRetryable: Bool) { self.init(message, kind: connectionRetryable ? .transport : .other) }
    public var errorDescription: String? { message }
}

public struct Harness: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let configured: Bool
    public let usesLegacySetup: Bool
    /// The listing embeds the harness even when the separate catalog has not loaded.
    public init?(reportedBy box: Sandbox) {
        guard let id = box.config.harnessConfigId, let config = box.harnessConfig,
              config["id"].string == id, !id.isEmpty, !config["name"].string.isEmpty else { return nil }
        self.id = id
        name = config["name"].string
        if case .bool(let ready) = config["configured"] { configured = ready; usesLegacySetup = true }
        else { configured = true; usesLegacySetup = false }
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        // New harnesses run without setup. Older servers send a readiness flag.
        let readiness = try values.decodeIfPresent(Bool.self, forKey: .configured)
        configured = readiness ?? true
        usesLegacySetup = readiness != nil
    }
    private enum CodingKeys: String, CodingKey { case id, name, configured }
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
