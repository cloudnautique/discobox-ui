import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DiscoboxCore

/// The provider keeps its otherwise-weak delegate alive through userInfo,
/// including if the user switches boxes while Finder is receiving the file.
final class RemoteFilePromiseWriter: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let entry: RemoteFile
    let access: FileAccess
    init(entry: RemoteFile, access: FileAccess) { self.entry = entry; self.access = access }

    @MainActor static func provider(for entry: RemoteFile, access: FileAccess) -> NSFilePromiseProvider {
        let writer = RemoteFilePromiseWriter(entry: entry, access: access)
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
        provider.userInfo = writer
        return provider
    }
    @MainActor func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let completion = FilePromiseCompletion(completionHandler)
        Task {
            do {
                // Finder supplies the final URL. The bridge stages atomically
                // and refuses to overwrite any existing local path.
                try await access.transfer(upload: false, remote: entry.path, local: url)
                completion.finish(nil)
            } catch { completion.finish(error) }
        }
    }
}

/// AppKit's completion block predates Sendable annotations. It is a one-shot
/// callback, used only after the asynchronous writer finishes.
private final class FilePromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    func finish(_ error: Error?) {
        let completion = lock.withLock { let value = callback; callback = nil; return value }
        completion?(error)
    }
}

/// Native table dragging supports multiple Finder file promises without
/// downloading anything until the destination accepts the drop.
struct FilesTable: NSViewRepresentable {
    let browser: FileBrowser
    let entries: [RemoteFile]
    let enabled: Bool
    @Binding var selection: Set<String>
    var download: ([RemoteFile]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let name = NSTableColumn(identifier: .init("name")); name.title = "Name"; name.width = 340; name.minWidth = 120
        let size = NSTableColumn(identifier: .init("size")); size.title = "Size"; size.width = 90; size.minWidth = 65; size.maxWidth = 110
        table.addTableColumn(name); table.addTableColumn(size)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.rowHeight = 32; table.intercellSpacing = NSSize(width: 8, height: 0)
        table.style = .inset
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openDirectory(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        table.setAccessibilityIdentifier("files.table")
        let menu = NSMenu(); menu.delegate = context.coordinator; menu.autoenablesItems = false
        for (title, action) in [("Download…", #selector(Coordinator.downloadSelection)), ("Copy Path", #selector(Coordinator.copyPaths))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = context.coordinator; menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent.entries
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if previous != entries || table.numberOfRows != entries.count { table.reloadData() }
        let rows = IndexSet(entries.indices.filter { selection.contains(entries[$0].path) })
        if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
        table.backgroundColor = NSColor(DiscoboxAppearance.canvas)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FilesTable
        weak var table: NSTableView?
        init(_ parent: FilesTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.entries.indices.contains(row) else { return nil }
            let file = parent.entries[row]
            if tableColumn?.identifier.rawValue == "size" {
                let label = NSTextField(labelWithString: file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.alignment = .right
                return label
            }
            let cell = NSTableCellView()
            let image = NSImageView(image: NSImage(systemSymbolName: file.isDirectory ? "folder.fill" : file.canTransfer ? "doc" : "link", accessibilityDescription: nil)!)
            image.contentTintColor = file.isDirectory ? NSColor(DiscoboxAppearance.accent) : .secondaryLabelColor
            let label = NSTextField(labelWithString: file.name)
            label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
            image.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image); cell.addSubview(label); cell.imageView = image; cell.textField = label
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 17), image.heightAnchor.constraint(equalToConstant: 17),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { parent.entries.indices.contains($0) ? parent.entries[$0].path : nil })
        }
        @objc func openDirectory(_ sender: Any?) {
            guard let table, parent.browser.canNavigate, parent.entries.indices.contains(table.clickedRow) else { return }
            let file = parent.entries[table.clickedRow]
            if file.isDirectory { Task { await parent.browser.load(file.path) } }
        }
        private var selectedFiles: [RemoteFile] { parent.entries.filter { parent.selection.contains($0.path) } }
        func menuWillOpen(_ menu: NSMenu) {
            if let table, table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            menu.items.first?.isEnabled = parent.enabled && !selectedFiles.isEmpty && selectedFiles.allSatisfy(\.canTransfer)
            menu.items.last?.isEnabled = !selectedFiles.isEmpty
        }
        @objc func downloadSelection() { parent.download(selectedFiles) }
        @objc func copyPaths() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedFiles.map(\.path).joined(separator: "\n"), forType: .string)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.enabled, parent.entries.indices.contains(row), parent.entries[row].canTransfer else { return nil }
            return RemoteFilePromiseWriter.provider(for: parent.entries[row], access: parent.browser.access)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.enabled, parent.browser.canTransfer, (info.draggingSource as? NSTableView) !== tableView,
                  info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            if operation == .on, parent.entries.indices.contains(row), parent.entries[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
            } else { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            guard parent.enabled, parent.browser.canTransfer, let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            let destination = operation == .on && parent.entries.indices.contains(row) && parent.entries[row].isDirectory ? parent.entries[row].path : parent.browser.directory
            parent.browser.upload(urls, to: destination)
            return true
        }
    }
}
