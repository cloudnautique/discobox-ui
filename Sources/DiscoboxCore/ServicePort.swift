import Foundation

public struct ServicePort: Decodable, Identifiable, Sendable {
    public let port: Int
    public let local: Int
    public let `protocol`: String
    public let serviceId: String
    public let serviceName: String
    public var id: String { "\(`protocol` == "udp" ? "udp" : "tcp"):\(port)" }
    public var isDesktop: Bool { serviceId == "ai.discobox.desktop" }
    public var address: String { "127.0.0.1:\(local)" }
    public var browserURL: URL? {
        guard ["http", "https"].contains(`protocol`), (1...65535).contains(local) else { return nil }
        return browserURL(as: `protocol`)
    }
    /// Explicit user choice for a TCP port whose application protocol is unknown.
    public func browserURL(as scheme: String) -> URL? {
        guard ["tcp", "http", "https"].contains(`protocol`), ["http", "https"].contains(scheme),
              (1...65535).contains(local) else { return nil }
        return URL(string: "\(scheme)://\(address)")
    }
}
public struct ServiceForwardSnapshot: Decodable, Sendable {
    public let ports: [ServicePort]
    public let error: String?
}

/// URLs printed inside a box name its network namespace, not this computer's.
public enum ForwardedServiceURL {
    public static func sandboxPort(_ url: URL) -> Int? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        let ipv4 = parts.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
        guard host == "localhost" || host == "::1" || host == "::" ||
                (ipv4 && (octets[0] == 127 || octets.allSatisfy { $0 == 0 })) else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// No mapping means no local URL: falling back could open an unrelated host app.
    public static func resolve(_ url: URL, ports: [ServicePort]) -> URL? {
        guard let remote = sandboxPort(url) else { return url }
        guard let binding = ports.first(where: { $0.port == remote && $0.protocol != "udp" }),
              (1...65535).contains(binding.local),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = "127.0.0.1"
        components.port = binding.local
        return components.url
    }
}
