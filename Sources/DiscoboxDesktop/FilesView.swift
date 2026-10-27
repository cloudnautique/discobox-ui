import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiscoboxCore

struct FilesView: View {
    @Environment(Workspace.self) private var workspace
    @State private var path = ""
    @State private var entries: [RemoteFile] = []
    @State private var access: FileAccess?
    @State private var error: String?
    @State private var busy = false
    @State private var transfer: Task<Void, Never>?
    @State private var bytes: Int64 = 0
    @State private var transferName = ""
    @State private var conflicts: [URL] = []
    @State private var showConflict = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { path = (path as NSString).deletingLastPathComponent; reload() } label: { Image(systemName: "arrow.up") }
                TextField("Path", text: $path).textFieldStyle(.roundedBorder).onSubmit { reload() }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
            }.padding(10)
            HStack {
                Button("Upload…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
                    panel.begin { response in if response == .OK { accept(panel.urls) } }
                }.disabled(busy)
                Spacer()
                Text("Drop files here").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 8)
            List(entries) { entry in
                HStack {
                    Label(entry.name, systemImage: entry.type == "directory" ? "folder" : "doc")
                    Spacer()
                    if entry.type == "directory" { Button { path = entry.path; reload() } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless) }
                    else { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if entry.type == "directory" { path = entry.path; reload() } }
                .contextMenu {
                    Button("Download…") { download(entry) }.disabled(busy || !["file", "directory"].contains(entry.type))
                    Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
                }
                .onDrag { promisedFile(entry) }
            }.listStyle(.inset)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard !busy else { return false }
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                        }
                        if let url { urls.append(url) }
                    }
                    accept(urls)
                }
                return true
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(transferName) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.caption).lineLimit(1)
                    Spacer(); Button("Cancel") { transfer?.cancel() }
                }.padding(10)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
        }
        .task {
            do {
                access = try workspace.fileAccess()
                path = workspace.execs.first(where: { $0.primary == true })?.workdir ?? "~"
                await readDirectory()
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { transfer?.cancel() }
        .confirmationDialog("Some names already exist. Replace matching regular files? Directory transfers merge files and may complete partially.", isPresented: $showConflict, titleVisibility: .visible) {
            Button("Replace existing files", role: .destructive) { upload(conflicts, replace: true) }
            Button("Skip existing names") { upload(conflicts.filter { local in !entries.contains { $0.name == local.lastPathComponent } }, replace: false) }
            Button("Cancel", role: .cancel) { conflicts = [] }
        }
    }
    private func reload() { Task { await readDirectory() } }
    private func readDirectory() async {
        guard let access else { return }
        let requested = path
        do {
            let directory = try await access.list(requested)
            guard !Task.isCancelled, path == requested else { return }
            path = directory.path; entries = directory.entries.sorted { if ($0.type == "directory") != ($1.type == "directory") { return $0.type == "directory" }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func accept(_ urls: [URL]) {
        guard !busy else { error = "A transfer is already running. Drop the remaining files after it finishes."; return }
        if urls.contains(where: { local in entries.contains { $0.name == local.lastPathComponent } }) { conflicts = urls; showConflict = true }
        else { upload(urls, replace: false) }
    }
    private func upload(_ urls: [URL], replace: Bool) {
        guard let access, !busy else { return }
        let directory = path
        busy = true; bytes = 0; error = nil
        transfer = Task {
            defer { busy = false; transfer = nil }
            for url in urls {
                if Task.isCancelled { break }
                transferName = url.lastPathComponent; bytes = 0
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await access.transfer(upload: true, remote: (directory as NSString).appendingPathComponent(url.lastPathComponent), local: url, replace: replace) { count in Task { @MainActor in bytes = count } }
                } catch { self.error = error.localizedDescription; break }
            }
            let transferError = error
            await readDirectory()
            if let transferError { error = transferError }
        }
    }
    private func download(_ entry: RemoteFile) {
        guard let access else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Download here"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            busy = true; bytes = 0; transferName = entry.name; error = nil
            transfer = Task {
                defer { busy = false; transfer = nil }
                do { try await access.transfer(upload: false, remote: entry.path, local: folder.appendingPathComponent(entry.name)) { count in Task { @MainActor in bytes = count } } }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func promisedFile(_ entry: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let access, ["file", "directory"].contains(entry.type) else { return provider }
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(forTypeIdentifier: entry.type == "directory" ? UTType.folder.identifier : UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: entry.type == "file" ? entry.size : -1)
            let task = Task {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discobox-drag-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let file = directory.appendingPathComponent(entry.name)
                    try await access.transfer(upload: false, remote: entry.path, local: file) { count in progress.completedUnitCount = count }
                    completion(file, false, nil)
                } catch { completion(nil, false, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
