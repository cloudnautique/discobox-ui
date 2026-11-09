import Foundation

/// Suggestions come from the selected server's cached boxes. Never transfer a
/// host-local directory or offer a URL containing embedded credentials.
public struct RepositoryChoice: Identifiable, Equatable, Sendable {
    public let source: String
    public let title: String
    public var id: String { source }
    public init?(box: Sandbox) {
        guard let source = box.config.source?["url"].string.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix("~"),
              let title = box.repository else { return nil }
        if let url = URL(string: source), url.scheme != nil {
            guard ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.user == nil || url.scheme == "ssh" else { return nil }
        } else if source.contains(":") && !source.hasPrefix("git@") { return nil }
        self.source = source; self.title = title
    }
    public static func recent(in boxes: [Sandbox], limit: Int = 12) -> [RepositoryChoice] {
        var seen = Set<String>()
        return boxes.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            .compactMap { RepositoryChoice(box: $0) }
            .filter { seen.insert($0.source).inserted }
            .prefix(max(0, limit)).map { $0 }
    }
}
