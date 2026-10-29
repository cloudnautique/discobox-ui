import Foundation
import SystemConfiguration

/// A friendly label for this app's enrollment, independent of its peer ID.
public enum ComputerIdentity {
    public static let systemName: String = {
        // Read the local setting directly; Host name resolution can involve DNS.
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return resolvedName(name ?? "", fallback: "My computer")
    }()

    public static func resolvedName(_ name: String, fallback: String = systemName) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public static func enrollmentCommand(peerID: String, name: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "discobox admin peer add \(quote(peerID)) --name \(quote(resolvedName(name)))"
    }
}
