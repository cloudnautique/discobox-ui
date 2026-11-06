import Foundation
import Observation

/// One Files panel owns one captured computer/box. Navigation never changes
/// the destination of an upload that is awaiting confirmation or in flight.
@MainActor @Observable public final class FileBrowser {
    public struct UploadConflict: Identifiable {
        public let id = UUID()
        public let files: [URL]
        public let directory: String
        public let existing: Set<String>
        public var count: Int { files.filter { existing.contains($0.lastPathComponent) }.count }
    }
    public enum ConflictChoice { case replace, skip, cancel }

    public let sourceDirectory: String
    public let access: FileAccess
    public var path: String
    public private(set) var directory: String
    public private(set) var entries: [RemoteFile] = []
    public private(set) var loading = false
    public private(set) var transferring = false
    public private(set) var bytes: Int64 = 0
    public private(set) var transferName = ""
    public private(set) var receipt: String?
    public var error: String?
    public private(set) var conflict: UploadConflict?
    private let workspace: Workspace
    private let connection: UUID
    private let box: String
    private var loaded = false
    private var active = true
    private var navigation = UUID()
    private var transferTask: Task<Void, Never>?

    public init(workspace: Workspace) throws {
        access = try workspace.fileAccess()
        self.workspace = workspace
        connection = workspace.connectionID
        box = workspace.sandboxID ?? ""
        let workdir = workspace.execs.first { $0.primary == true }?.workdir ?? ""
        sourceDirectory = workdir.isEmpty || workdir == "~" ? "/workspace/source" : workdir
        path = sourceDirectory
        directory = sourceDirectory
    }

    public var isCurrent: Bool {
        active && workspace.connectionID == connection && workspace.sandboxID == box && workspace.selectedBox?.isRunning == true
    }
    public var canNavigate: Bool { isCurrent && !transferring && conflict == nil }
    public var canTransfer: Bool { canNavigate && loaded && !loading }

    public func load(_ requested: String? = nil) async {
        guard canNavigate else { return }
        let request = UUID()
        navigation = request
        let target = requested ?? path
        path = target
        loading = true
        defer { if navigation == request { loading = false } }
        do {
            let result = try await access.list(target)
            guard isCurrent, navigation == request, !Task.isCancelled else { return }
            directory = result.path
            path = result.path
            entries = result.entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            loaded = true
            error = nil
        } catch {
            guard isCurrent, navigation == request, !Task.isCancelled else { return }
            path = directory
            self.error = error.localizedDescription
        }
    }

    public func upload(_ files: [URL], to target: String? = nil) {
        guard canTransfer, !files.isEmpty else { return }
        let destination = target ?? directory
        guard files.allSatisfy({ $0.isFileURL && Self.safeName($0.lastPathComponent) }) else {
            error = "Drop files or folders from this computer."; return
        }
        guard Set(files.map(\.lastPathComponent)).count == files.count else {
            error = "Some selected files have the same name. Transfer them separately."; return
        }
        transferring = true; error = nil; receipt = nil; bytes = 0
        transferName = "Checking destination…"
        transferTask = Task { [self] in
            do {
                // Check the actual target, including folder-row drops. The write
                // still uses create-only/version checks to cover concurrent edits.
                let destinationFiles = try await access.list(destination)
                try Task.checkCancellation()
                guard isCurrent else { finish(); return }
                let existing = Set(destinationFiles.entries.map(\.name))
                if files.contains(where: { existing.contains($0.lastPathComponent) }) {
                    conflict = .init(files: files, directory: destinationFiles.path, existing: existing)
                    finish()
                } else {
                    await write(files, to: destinationFiles.path, replace: false)
                }
            } catch { failed(error) }
        }
    }

    public func resolveConflict(_ choice: ConflictChoice) {
        guard let pending = conflict else { return }
        conflict = nil
        guard isCurrent, choice != .cancel else { return }
        let files = choice == .skip ? pending.files.filter { !pending.existing.contains($0.lastPathComponent) } : pending.files
        guard !files.isEmpty else { receipt = "No files copied."; return }
        transferring = true; error = nil; bytes = 0
        transferTask = Task { await write(files, to: pending.directory, replace: choice == .replace) }
    }

    private func write(_ files: [URL], to destination: String, replace: Bool) async {
        var copied = 0
        do {
            for file in files {
                try Task.checkCancellation()
                guard isCurrent else { throw CancellationError() }
                transferName = "Uploading \(file.lastPathComponent) (\(copied + 1)/\(files.count))"
                bytes = 0
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                try await access.transfer(upload: true, remote: (destination as NSString).appendingPathComponent(file.lastPathComponent), local: file, replace: replace) { [weak self] count in
                    Task { @MainActor in self?.bytes = count }
                }
                copied += 1
            }
            receipt = "Copied \(copied) \(copied == 1 ? "item" : "items") to \(destination)."
            finish()
            await load(directory)
        } catch {
            failed(error, copied: copied)
            let failure = self.error
            await load(directory)
            self.error = failure
        }
    }

    public func download(_ files: [RemoteFile], to folder: URL) {
        guard canTransfer, !files.isEmpty, files.allSatisfy(\.canTransfer) else { return }
        transferring = true; error = nil; receipt = nil; bytes = 0
        transferTask = Task { [self] in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var copied = 0
            do {
                for file in files {
                    try Task.checkCancellation()
                    guard isCurrent else { throw CancellationError() }
                    transferName = "Downloading \(file.name) (\(copied + 1)/\(files.count))"; bytes = 0
                    try await access.transfer(upload: false, remote: file.path, local: folder.appendingPathComponent(file.name)) { [weak self] count in
                        Task { @MainActor in self?.bytes = count }
                    }
                    copied += 1
                }
                receipt = "Saved \(copied) \(copied == 1 ? "item" : "items") to \(folder.lastPathComponent)."
                finish()
            } catch { failed(error, copied: copied) }
        }
    }

    public func cancelTransfer() { transferTask?.cancel() }
    public func close() { active = false; navigation = UUID(); loading = false; conflict = nil; transferTask?.cancel() }
    private func finish() { transferring = false; transferTask = nil }
    private func failed(_ failure: Error, copied: Int = 0) {
        if isCurrent {
            error = (failure is CancellationError ? "Transfer cancelled." : failure.localizedDescription) +
                (copied > 0 ? " \(copied) items already copied." : "")
        }
        finish()
    }
    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}
