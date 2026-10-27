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
public struct ApprovalItem: Decodable, Identifiable, Sendable {
    public let kind: String
    public let credential: JSONValue?
    public let trust: JSONValue?
    public var request: JSONValue { credential ?? trust ?? .null }
    public var id: String { request["id"].string }
    public var boxID: String { request["sandboxId"].string }
    public var title: String {
        if kind == "trust" { return "Trust " + request["host"].string }
        let name = request["name"].string.isEmpty ? request["wellKnownId"].string : request["name"].string
        return (request["reason"].string == "refresh" ? "Refresh " : "Approve ") + (name.isEmpty ? "credential" : name)
    }
}
