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
        return URL(string: "\(`protocol`)://\(address)")
    }
}
public struct ServiceForwardSnapshot: Decodable, Sendable {
    public let ports: [ServicePort]
    public let error: String?
}
