import Foundation

public struct RemoteFile: Decodable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let type: String
    public let size: Int64
    public let version: String
    public var id: String { path }
}
public struct RemoteDirectory: Decodable, Sendable { public let path: String; public let entries: [RemoteFile] }
public struct FileAccess: Sendable {
    let client: any DiscoboxClient
    let project: String
    let box: String
    public func list(_ path: String) async throws -> RemoteDirectory {
        let directory = try await client.decode(.init(.files, projectID: project, sandboxID: box, remotePath: path), as: RemoteDirectory.self)
        guard directory.entries.allSatisfy({ !$0.name.isEmpty && $0.name != "." && $0.name != ".." && !$0.name.contains("/") && !$0.name.contains("\\") && !$0.name.contains("\0") }) else { throw DiscoboxError("The server returned an unsafe file name.") }
        return directory
    }
    public func transfer(upload: Bool, remote: String, local: URL, replace: Bool = false, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let request = BridgeRequest(upload ? .upload : .download, projectID: project, sandboxID: box, action: replace ? "replace" : nil, remotePath: remote, localPath: local.path)
        if let companion = client as? CompanionClient { _ = try await companion.perform(request, progress: progress) }
        else { _ = try await client.perform(request) }
    }
}
