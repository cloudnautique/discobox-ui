import Foundation
import Darwin

public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String { endpoint }
    public let name: String
    public let endpoint: String
    public let relayURLs: String
    public let directOnly: Bool?
    public init(name: String, endpoint: String, relayURLs: String = "", directOnly: Bool = false) {
        self.name = name
        self.endpoint = endpoint
        self.relayURLs = relayURLs
        self.directOnly = directOnly
    }
    public static let thisComputer = localComputer(name: "")
    public static func localComputer(name: String) -> ConnectionProfile {
        ConnectionProfile(name: ComputerIdentity.resolvedName(name), endpoint: "unix://")
    }
    public var isRemote: Bool { ["discobox", "iroh"].contains(URLComponents(string: endpoint)?.scheme?.lowercased() ?? "") }
    public var subtitle: String { isRemote ? "Remote computer" : endpoint.hasPrefix("unix:") ? "Local socket" : "HTTP/S server" }
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint == "unix://" { return ComputerIdentity.resolvedName(trimmed) + " (This computer)" }
        guard !trimmed.isEmpty, trimmed != endpoint else {
            return isRemote ? "Remote computer" : endpoint.hasPrefix("unix:") ? "Local socket" : URLComponents(string: endpoint)?.host ?? "Server"
        }
        return trimmed
    }
}

public enum ConnectionProfiles {
    public static var defaultSocket: String {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let base = runtime ?? FileManager.default.temporaryDirectory.appendingPathComponent("discobox-\(getuid())").path
        return URL(fileURLWithPath: base).appendingPathComponent("discobox/server.sock").path
    }
    public static func normalizedEndpoint(_ text: String, defaultSocket: String = defaultSocket) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("unix:") else { return text }
        guard let url = URLComponents(string: text) else { return text }
        if url.path.isEmpty && (url.host ?? "").isEmpty { return "unix://" }
        guard (url.host ?? "").isEmpty else { return text }
        let path = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath().path
        let standard = URL(fileURLWithPath: defaultSocket).standardizedFileURL.resolvingSymlinksInPath().path
        return path == standard ? "unix://" : text
    }
    /// Read the original saved-connections format, keeping custom sockets intact.
    public static func decode(_ text: String, defaultSocket: String = defaultSocket) -> [ConnectionProfile]? {
        guard let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: Data(text.utf8)) else { return nil }
        var profiles: [ConnectionProfile] = []
        for profile in saved {
            let endpoint = normalizedEndpoint(profile.endpoint, defaultSocket: defaultSocket)
            guard endpoint != "unix://" else { continue }
            profiles.removeAll { $0.endpoint == endpoint }
            profiles.append(.init(name: profile.displayName, endpoint: endpoint, relayURLs: profile.relayURLs, directOnly: profile.directOnly ?? false))
        }
        return profiles
    }
    public static func encode(_ profiles: [ConnectionProfile]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func validated(name: String, endpoint: String, relayURLs: String, directOnly: Bool) throws -> ConnectionProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = normalizedEndpoint(endpoint)
        guard !name.isEmpty else { throw DiscoboxError("Give this connection a name.") }
        guard let parts = URLComponents(string: endpoint), let scheme = parts.scheme?.lowercased(),
              ["unix", "discobox", "iroh", "http", "https"].contains(scheme) else {
            throw DiscoboxError("Use a Discobox address, an absolute unix:/// socket address, or an HTTP/S URL.")
        }
        if scheme == "unix" {
            guard endpoint == "unix://" || ((parts.host ?? "").isEmpty && parts.path.hasPrefix("/")) else {
                throw DiscoboxError("Use an absolute socket address, such as unix:///path/server.sock.")
            }
        } else if (parts.host ?? "").isEmpty { throw DiscoboxError("The server address is missing its host or peer ID.") }
        return ConnectionProfile(name: name, endpoint: endpoint, relayURLs: relayURLs, directOnly: directOnly)
    }
    /// Probe with a separate client; never replace the workspace's connection.
    public static func test(client: any DiscoboxClient) async throws {
        defer { client.closeConnection() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            _ = try await client.prepareConnection()
            try Task.checkCancellation()
            _ = try await client.decode(.init(.defaultProject), as: Project.self)
            try Task.checkCancellation()
        } onCancel: { client.closeConnection() }
    }
}
