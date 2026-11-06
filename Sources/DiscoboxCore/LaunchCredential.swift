import Foundation

/// An inline token assigned only to the box being created. Never persist a draft
/// in preferences or include its value in descriptions or validation errors.
public struct LaunchCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let environment: String
    public let host: String
    private let value: String

    public init(environment: String, host: String, value: String) {
        self.environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.value = value
    }

    public var description: String { "LaunchCredential(value: <redacted>)" }
    public var debugDescription: String { description }

    public static func payload(_ credentials: [Self]) throws -> JSONValue? {
        guard !credentials.isEmpty else { return nil }
        guard credentials.count <= 16 else { throw DiscoboxError("Add at most 16 credentials per box.") }
        var names = Set<String>()
        let secrets = try credentials.enumerated().map { index, credential -> JSONValue in
            let label = "Credential \(index + 1)"
            guard credential.environment.utf8.count <= 128,
                  credential.environment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw DiscoboxError("\(label): enter an environment variable such as OBOT_MCP_TOKEN.")
            }
            guard names.insert(credential.environment).inserted else {
                throw DiscoboxError("Each credential needs a different environment variable.")
            }
            guard credential.host.utf8.count <= 253,
                  credential.host.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$"#, options: .regularExpression) != nil,
                  credential.host.split(separator: ".").allSatisfy({ $0.utf8.count <= 63 }) else {
                throw DiscoboxError("\(label): enter a destination hostname, without https://, a port, or a path.")
            }
            guard !credential.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credential.value.contains("\0"), credential.value.utf8.count <= 16_384 else {
                throw DiscoboxError("\(label): enter a token of at most 16 KB.")
            }
            return .object(["env": .string(credential.environment), "host": .string(credential.host), "value": .string(credential.value)])
        }
        let payload = JSONValue.object(["secrets": .array(secrets)])
        guard try JSONEncoder().encode(payload).count <= 65_536 else {
            throw DiscoboxError("The launch credentials are too large. Keep the total below 64 KB.")
        }
        return payload
    }
}
