import Foundation
import Darwin

/// Event-driven state from the local bridge, never inferred from terminal text.
/// The private FIFO is independent of the PTY and carries no terminal input.
@MainActor final class TerminalAttachStatus {
    let path: String
    var receive: ((String, String?) -> Void)?
    private let directory: URL
    private var source: DispatchSourceRead?
    private var pending = Data()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("discobox-terminal-" + UUID().uuidString)
        path = directory.appendingPathComponent("status").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard mkfifo(path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        // Keep one local writer open so there is no EOF spin before the child
        // connects. CLOEXEC prevents Ghostty's child inheriting this endpoint.
        let descriptor = Darwin.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { @Sendable [weak self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(count))
                Task { @MainActor [weak self] in self?.consume(data) }
            }
        }
        source.setCancelHandler { @Sendable in Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    private func consume(_ data: Data) {
        guard source != nil else { return }
        pending.append(data)
        guard pending.count <= 8192 else { close(); return }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end])
            pending.removeSubrange(...end)
            struct Record: Decodable { let state: String; let error: String? }
            if let value = try? JSONDecoder().decode(Record.self, from: line),
               ["connecting", "connected", "reconnecting", "reconnected", "disconnected", "ended", "output-stalled"].contains(value.state) { receive?(value.state, value.error) }
        }
    }

    func close() {
        receive = nil
        source?.cancel(); source = nil
        pending.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
