import Foundation

/// Preserve policy variables and certificate material exactly as returned by the
/// server. Re-encoding an approval must not silently drop unknown policy fields.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var pretty: String { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}
public struct ApprovalInbox: Decodable, Sendable { public let approvalRequests: [ApprovalItem] }
public struct ApprovalItem: Decodable, Identifiable, Sendable, Equatable {
    public let kind: String
    public let credential: JSONValue?
    public let trust: JSONValue?
    public let refresh: JSONValue?
    public let adoption: JSONValue?
    public let apiAccess: JSONValue?
    private let future: JSONValue?
    public init(kind: String, credential: JSONValue? = nil, trust: JSONValue? = nil, refresh: JSONValue? = nil, adoption: JSONValue? = nil, apiAccess: JSONValue? = nil) {
        self.kind = kind; self.credential = credential; self.trust = trust
        self.refresh = refresh; self.adoption = adoption; self.apiAccess = apiAccess; future = nil
    }
    public init(from decoder: any Decoder) throws {
        let root = try JSONValue(from: decoder)
        kind = root["kind"].string
        func value(_ key: String) -> JSONValue? { root[key] == .null ? nil : root[key] }
        credential = value("credential"); trust = value("trust"); refresh = value("refresh")
        adoption = value("adoption"); apiAccess = value("apiAccess"); future = ["credential", "trust", "refresh", "adoption", "apiAccess"].contains(kind) ? nil : value(kind)
    }
    public var request: JSONValue {
        switch kind {
        case "credential": credential ?? .null
        case "trust": trust ?? .null
        case "refresh": refresh ?? .null
        case "adoption": adoption ?? .null
        case "apiAccess": apiAccess ?? .null
        default: future ?? .null
        }
    }
    public var supported: Bool { ["credential", "trust", "refresh", "adoption", "apiAccess"].contains(kind) }
    public var id: String { request["id"].string }
    public var boxID: String {
        let requester = request["requesterSandboxId"].string
        return requester.isEmpty ? request["sandboxId"].string : requester
    }
    public var title: String {
        switch kind {
        case "trust": return "Trust " + request["host"].string
        case "apiAccess": return "Allow Discobox API access?"
        case "adoption": return "Allow this box to lead another box?"
        case "refresh": return "Refresh " + (request["secretName"].string.isEmpty ? "credential" : request["secretName"].string)
        case "credential":
            let name = request["name"].string.isEmpty ? request["wellKnownId"].string : request["name"].string
            return (request["reason"].string == "refresh" ? "Refresh " : "Approve ") + (name.isEmpty ? "credential" : name)
        default: return "Review " + kind + " request"
        }
    }
}
