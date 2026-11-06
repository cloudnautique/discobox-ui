import SwiftUI
import AppKit
import DiscoboxCore

struct FilesView: View {
    @Environment(Workspace.self) private var workspace
    @State private var browser: FileBrowser?
    @State private var failure: String?
    @State private var selection: Set<String> = []

    var body: some View {
        Group {
            if let browser { panel(browser) }
            else if let failure { ContentUnavailableView("Files unavailable", systemImage: "folder.badge.questionmark", description: Text(failure)) }
            else { ProgressView("Opening source folder…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(DiscoboxAppearance.canvas)
        .task(id: workspace.connectionID) {
            do {
                let model = try FileBrowser(workspace: workspace)
                browser = model
                await model.load()
            } catch { failure = error.localizedDescription }
        }
        .onDisappear { browser?.close() }
    }

    private func panel(_ browser: FileBrowser) -> some View {
        @Bindable var browser = browser
        let selected = browser.entries.filter { selection.contains($0.path) }
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button { Task { await browser.load(browser.sourceDirectory) } } label: { Label("Source", systemImage: "folder.badge.gearshape") }
                        .help("Open the box’s source working directory").accessibilityIdentifier("files.source")
                    Button { Task { await browser.load((browser.directory as NSString).deletingLastPathComponent) } } label: { Image(systemName: "arrow.up") }
                        .help("Enclosing folder").disabled(browser.directory == "/")
                    Spacer(minLength: 0)
                    Button { chooseUpload(browser) } label: { Label("Upload…", systemImage: "arrow.up.doc") }.disabled(!browser.canTransfer)
                    Button { chooseDownload(selected, browser: browser) } label: { Image(systemName: "arrow.down.doc") }
                        .disabled(!browser.canTransfer || selected.isEmpty || !selected.allSatisfy(\.canTransfer)).help("Download selected files or folders…")
                    Button { Task { await browser.load(browser.directory) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh folder").accessibilityIdentifier("files.refresh")
                }.buttonStyle(.borderless).foregroundStyle(DiscoboxAppearance.accent)
                TextField("Folder path", text: $browser.path)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .onSubmit { Task { await browser.load() } }.accessibilityIdentifier("files.path")
            }.padding(12).disabled(!browser.canNavigate).background(DiscoboxAppearance.chrome)
            Divider()
            FilesTable(browser: browser, entries: browser.entries, enabled: browser.canTransfer, selection: $selection) {
                chooseDownload($0, browser: browser)
            }
            .overlay {
                if browser.loading { ProgressView().padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).allowsHitTesting(false) }
                else if browser.entries.isEmpty, let error = browser.error {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Files unavailable").font(.headline)
                        Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                        Button("Try Again") { Task { await browser.load(browser.directory) } }.controlSize(.small)
                    }.padding(24).frame(maxWidth: 470)
                }
                else if browser.entries.isEmpty && browser.error == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(DiscoboxAppearance.accent)
                        Text("Drop files into this folder").font(.system(size: 13, weight: .medium))
                        Text("Files are copied to the selected box.").font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
            Divider()
            if browser.transferring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(browser.transferName).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: browser.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("Cancel") { browser.cancelTransfer() }.controlSize(.small)
                }.padding(10).background(DiscoboxAppearance.surface)
            }
            if let error = browser.error, !browser.entries.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { browser.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss error")
                }.font(.system(size: 11)).foregroundStyle(.orange).padding(10)
            }
            HStack {
                Text(selection.isEmpty ? "\(browser.entries.count) items" : "\(selection.count) selected")
                Spacer()
                Text(browser.receipt ?? "Drag in to upload · Drag out to save").lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30).background(DiscoboxAppearance.chrome)
        }
        .onChange(of: browser.directory) { selection = [] }
        .sheet(item: Binding(get: { browser.conflict }, set: { if $0 == nil { browser.resolveConflict(.cancel) } })) { conflict in
            FileConflictSheet(directory: conflict.directory, count: conflict.count, resolve: browser.resolveConflict)
        }
    }
    private func chooseUpload(_ browser: FileBrowser) {
        let destination = browser.directory
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Upload"; panel.message = "Copy files and folders to \(destination) in the selected box."
        panel.begin { response in if response == .OK { browser.upload(panel.urls, to: destination) } }
    }
    private func chooseDownload(_ files: [RemoteFile], browser: FileBrowser) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Save Here"
        panel.message = "Choose where to save \(files.count == 1 ? files[0].name : "the selected items"). Existing local files won’t be replaced."
        panel.begin { response in
            if response == .OK, let folder = panel.url { browser.download(files, to: folder) }
        }
    }
}

struct FileConflictSheet: View {
    let directory: String
    let count: Int
    let resolve: (FileBrowser.ConflictChoice) -> Void
    var body: some View {
        StudioConfirmation(title: "Files already exist", symbol: "doc.on.doc", subtitle: "\(count) matching names in the destination") {
            VStack(alignment: .leading, spacing: 18) {
                Text(directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Replace matching files or skip existing names. Folders merge their contents; files copied before a cancellation remain in the box.").font(.system(size: 12))
            }
        } footer: {
            HStack {
                Button("Cancel", role: .cancel) { resolve(.cancel) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip Existing") { resolve(.skip) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                Button("Replace", role: .destructive) { resolve(.replace) }.tint(.red)
            }
        }
    }
}
