import Foundation
import Observation

@MainActor @Observable public final class ApprovalQueue {
    public let workspace: Workspace
    public let boxID: String?
    public let connection: UUID
    public var selection: String?
    public private(set) var reviewing: ApprovalItem?
    public init(workspace: Workspace, boxID: String?) {
        self.workspace = workspace; self.boxID = boxID; connection = workspace.connectionID
    }
    public var valid: Bool { workspace.connectionID == connection && workspace.isConnected }
    public var requests: [ApprovalItem] { valid ? workspace.approvals.filter { boxID == nil || $0.boxID == boxID } : [] }
    public var selected: ApprovalItem? { requests.first { $0.id == selection } }
    public func synchronize() {
        if selected == nil { selection = requests.first?.id }
    }
    public func review(_ item: ApprovalItem) {
        guard valid, !item.id.isEmpty, let current = requests.first(where: { $0.id == item.id }) else { return }
        selection = current.id; reviewing = current
    }
    public func reviewSelected() { if let selected { review(selected) } }
    public func back() { reviewing = nil; synchronize() }
}

public extension ApprovalItem {
    var intent: String {
        switch kind {
        case "credential":
            if request["use"] != .null && request["delegate"] != .null { return "Use and share" }
            if request["delegate"] != .null || request["purpose"].string == "delegate" { return "Share with child boxes" }
            return request["reason"].string == "refresh" ? "Update credential" : "Use in this box"
        case "trust": return "Trust certificate"
        case "refresh": return "Update credential"
        case "apiAccess": return "Discobox API access"
        case "adoption": return "Lead another box"
        default: return "Requires a newer client"
        }
    }
    var reviewTitle: String {
        let name = request["name"].string.isEmpty ? request["wellKnownId"].string : request["name"].string
        if kind == "credential" { return name.isEmpty ? "Credential access" : name }
        return title
    }
    var destinationSummary: String {
        var hosts = request["hosts"].array.map(\.string)
        if !request["host"].string.isEmpty { hosts.append(request["host"].string) }
        for part in ["use", "delegate"] {
            for route in request[part]["routes"].array where route["blocked"] != .bool(true) {
                hosts += route["hosts"].array.map(\.string)
            }
        }
        return Set(hosts.filter { !$0.isEmpty }).sorted().joined(separator: ", ")
    }
}
