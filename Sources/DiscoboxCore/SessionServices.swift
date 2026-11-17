import Foundation

/// Internal request construction shared by named, scoped feature APIs. Views
/// never supply an arbitrary bridge operation or resolve an active computer here.
@MainActor struct ScopedAPI {
    let connection: ConnectionStore
    func json(_ operation: BridgeRequest.Operation, box: String? = nil, request: String? = nil,
              kind: String? = nil, secret: String? = nil, record: String? = nil, link: String? = nil,
              action: String? = nil, payload: JSONValue? = nil,
              localPath: String? = nil, pool: String? = nil, harness: String? = nil) async throws -> JSONValue {
        let access = try connection.capture()
        let data = try await access.perform(.init(operation, projectID: access.scope.project, sandboxID: box, harnessID: harness,
            requestID: request, kind: kind, secretID: secret, recordID: record, link: link, action: action, payload: payload,
            localPath: localPath, poolID: pool))
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

@MainActor public struct CredentialService {
    let connection: ConnectionStore
    public func list() async throws -> [JSONValue] { try await ScopedAPI(connection: connection).json(.secrets)["secrets"].array }
    public func create(payload: JSONValue) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.createSecret, payload: payload) }
    public func updateLimits(id: String, payload: JSONValue) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.updateSecretLimits, secret: id, payload: payload) }
    public func delete(id: String) async throws { _ = try await ScopedAPI(connection: connection).json(.deleteSecret, secret: id) }
}

@MainActor public struct HarnessService {
    let connection: ConnectionStore
    public func details(harness: String) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.harnessDetails, harness: harness) }
    public func changes(harness: String, box: String) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.harnessChanges, box: box, harness: harness) }
    public func save(harness: String, box: String, payload: JSONValue) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.saveHarnessChanges, box: box, payload: payload, harness: harness) }
    public func discard(harness: String, box: String, payload: JSONValue) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.discardHarnessChanges, box: box, payload: payload, harness: harness) }
}

@MainActor public struct AuditService {
    let connection: ConnectionStore
    public func snapshot(box: String, cursor: JSONValue? = nil) async throws -> AuditSnapshot {
        let access = try connection.capture()
        let data = try await access.perform(.init(.audit, projectID: access.scope.project, sandboxID: box, payload: cursor))
        return try JSONDecoder().decode(AuditSnapshot.self, from: data)
    }
    /// A bounded preview of one recorded body (`part`: request, response or stream).
    public func body(_ record: AuditRecordReference, part: String, box: String) async throws -> JSONValue {
        try await ScopedAPI(connection: connection).json(.auditBody, box: box, record: record.record, action: part, pool: record.pool)
    }
    public func save(_ record: AuditRecordReference, part: String, box: String, to destination: URL) async throws -> JSONValue {
        try await ScopedAPI(connection: connection).json(.saveAuditBody, box: box, record: record.record, action: part, localPath: destination.path, pool: record.pool)
    }
}

@MainActor public struct PoolSettingsService {
    let connection: ConnectionStore
    public func read(pool: String) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.poolConfiguration, pool: pool) }
    public func update(pool: String, payload: JSONValue) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.updatePoolProxy, payload: payload, pool: pool) }
}

@MainActor public struct ToolService {
    let connection: ConnectionStore
    public func list(box: String?) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.tools, box: box) }
}

@MainActor public struct LinkService {
    let connection: ConnectionStore
    public func peer() async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.serverPeer) }
    public func parse(_ url: String, hints: JSONValue?) async throws -> JSONValue { try await ScopedAPI(connection: connection).json(.boxLink, link: url, payload: hints) }
}
