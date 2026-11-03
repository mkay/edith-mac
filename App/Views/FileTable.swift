// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import Quartz
import EdithEditor
import SwiftUI
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A remote path dragged within Edith, for moving files between folders.
    static let remotePath = NSPasteboard.PasteboardType("de.singular.edith.remote-path")
}

/// The file list: an NSTableView, for what SwiftUI's Table can't do well —
/// dragging files out to Finder as promises downloaded on drop, dropping
/// files in to upload or onto folders to move, and per-row context menus.
struct FileTable: NSViewRepresentable {
    let connection: Connection
    let entries: [RemoteFile]
    let path: String
    let showDetails: Bool
    let sortKey: Browser.SortKey
    let ascending: Bool
    let singleClickOpens: Bool
    @Environment(WindowModel.self) private var window

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let c = NSTableColumn(identifier: column.identifier)
            c.title = column.title
            c.width = column.width
            c.minWidth = column == .name ? 120 : 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            if column == .size { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.action = #selector(Coordinator.clicked(_:))
        table.menu = NSMenu()
        table.menu?.delegate = coordinator
        table.registerForDraggedTypes([.fileURL, .remotePath])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.keyHandler = { [weak coordinator] key in coordinator?.handle(key) ?? false }
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.connection = connection
        coordinator.window = window
        coordinator.singleClickOpens = singleClickOpens
        guard let table = coordinator.table else { return }

        for column in Column.allCases where column != .name {
            table.tableColumn(withIdentifier: column.identifier)?.isHidden = !showDetails
        }
        let descriptor = NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)
        if table.sortDescriptors.first != descriptor {
            coordinator.applyingSort = true
            table.sortDescriptors = [descriptor]
            coordinator.applyingSort = false
        }
        coordinator.update(entries: entries, path: path)
    }

    // MARK: Columns

    enum Column: String, CaseIterable {
        case name, size, modified, permissions, owner, group

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var sortKey: Browser.SortKey { Browser.SortKey(rawValue: rawValue)! }
        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .modified: "Modified"
            case .permissions: "Permissions"
            case .owner: "Owner"
            case .group: "Group"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 240
            case .size: 70
            case .modified: 140
            case .permissions: 90
            case .owner, .group: 70
            }
        }
    }

    enum Row: Equatable {
        case parent(String)
        case file(RemoteFile)

        var path: String {
            switch self {
            case .parent(let p): p
            case .file(let f): f.path
            }
        }

        var isDirectory: Bool {
            switch self {
            case .parent: true
            case .file(let f): f.isDirectory
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        weak var table: FileTableView?
        var connection: Connection?
        var window: WindowModel?
        var applyingSort = false
        var singleClickOpens = false
        private var rows: [Row] = []
        private var shownPath = ""

        func update(entries: [RemoteFile], path: String) {
            var new: [Row] = path == "/" ? [] : [.parent(remoteParent(path))]
            new += entries.map(Row.file)
            guard new != rows || path != shownPath, let table else { return }

            // Keep the selection across reloads of the same folder.
            let selected = path == shownPath ? Set(selectedFiles.map(\.path)) : []
            rows = new
            let changedFolder = path != shownPath
            shownPath = path
            table.reloadData()
            let keep = IndexSet(rows.indices.filter { if case .file(let f) = rows[$0] { selected.contains(f.path) } else { false } })
            table.selectRowIndexes(keep, byExtendingSelection: false)
            if changedFolder { table.scrollRowToVisible(0) }
        }

        private func file(at row: Int) -> RemoteFile? {
            guard rows.indices.contains(row), case .file(let f) = rows[row] else { return nil }
            return f
        }

        var selectedFiles: [RemoteFile] {
            table?.selectedRowIndexes.compactMap(file(at:)) ?? []
        }

        /// What a context-menu command applies to: the clicked row if it's
        /// outside the selection, else the whole selection, as in Finder.
        private var targetFiles: [RemoteFile] {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                return file(at: clicked).map { [$0] } ?? []
            }
            return selectedFiles
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell(column: column)
            cell.identifier = id
            switch rows[row] {
            case .parent:
                cell.show(column == .name ? ".." : "", icon: column == .name ? FileIcons.parent : nil, secondary: true)
            case .file(let f):
                switch column {
                case .name: cell.show(f.name, icon: FileIcons.icon(for: f), secondary: f.name.hasPrefix("."))
                case .size: cell.show(f.isDirectory ? "—" : f.size.formatted(.byteCount(style: .file)))
                case .modified: cell.show(f.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                case .permissions: cell.show(f.permissionsString, monospaced: true)
                case .owner: cell.show(f.owner.isEmpty ? "—" : f.owner)
                case .group: cell.show(f.group.isEmpty ? "—" : f.group)
                }
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            file(at: row)?.name
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let browser = connection?.browser,
                  let first = tableView.sortDescriptors.first,
                  let key = first.key.flatMap(Browser.SortKey.init(rawValue:))
            else { return }
            browser.sortKey = key
            browser.ascending = first.ascending
        }

        // MARK: Opening

        @objc func doubleClicked(_ sender: NSTableView) {
            guard !singleClickOpens else { return }
            activate(row: sender.clickedRow)
        }

        /// With the single-click preference, a plain click opens; a click with
        /// ⌘ or ⇧ still just selects.
        @objc func clicked(_ sender: NSTableView) {
            guard singleClickOpens, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            activate(row: sender.clickedRow)
        }

        private func activate(row: Int) {
            guard rows.indices.contains(row) else { return }
            switch rows[row] {
            case .parent(let path): window?.navigate(to: path)
            case .file(let f): window?.open(f)
            }
        }

        func handle(_ key: FileTableView.Key) -> Bool {
            guard let window, let table else { return false }
            switch key {
            case .open:
                guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first else { return false }
                activate(row: row)
            case .up:
                guard let browser = connection?.browser, browser.canGoUp else { return false }
                Task { await browser.goUp() }
            case .delete:
                window.confirmDelete(selectedFiles)
            case .rename:
                guard selectedFiles.count == 1 else { return false }
                window.rename(selectedFiles[0])
            case .quickLook:
                quickLook()
            }
            return true
        }

        // MARK: Quick Look

        /// Space shows the selected files in Quick Look, as in Finder, after
        /// downloading them; Space again closes the panel.
        private func quickLook() {
            guard let table, let panel = QLPreviewPanel.shared() else { return }
            if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
                panel.orderOut(nil)
                return
            }
            let files = selectedFiles.filter { !$0.isDirectory }
            guard let session = connection?.session, !files.isEmpty else { return }
            Task {
                var urls: [URL] = []
                for file in files {
                    guard let local = try? TempFiles.shared.path(for: file.path) else { continue }
                    do {
                        try await session.download(file, to: local)
                        urls.append(local)
                    } catch {
                        break
                    }
                }
                guard !urls.isEmpty else { return }
                table.previewItems = urls
                table.window?.makeFirstResponder(table)
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let window, let connection else { return }
            let files = targetFiles
            let single = files.count == 1 ? files.first : nil

            menu.addItem(ClosureMenuItem(String(localized: "New File…")) { window.newFile() })
            menu.addItem(ClosureMenuItem(String(localized: "New Folder…")) { window.newFolder() })
            if !files.isEmpty {
                menu.addItem(.separator())
                let actions = NSMenu()
                actions.addItem(ClosureMenuItem(String(localized: "Move to…")) { window.chooseDestination(moving: files) })
                actions.addItem(ClosureMenuItem(String(localized: "Copy to…")) { window.chooseDestination(copying: files) })
                actions.addItem(ClosureMenuItem(String(localized: "Duplicate")) { window.duplicate(files) })
                if let single {
                    if Minifier.Kind(fileName: single.name) != nil {
                        actions.addItem(ClosureMenuItem(String(localized: "Minify")) { window.minify(single) })
                    }
                    actions.addItem(ClosureMenuItem(String(localized: "Create Archive…")) { window.createArchive(of: single) })
                }
                menu.addItem(submenu("Actions", actions))
                if let single { menu.addItem(ClosureMenuItem(String(localized: "Rename…")) { window.rename(single) }) }
                menu.addItem(ClosureMenuItem(String(localized: "Delete…")) { window.confirmDelete(files) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(files.count == 1 ? String(localized: "Download…") : String(localized: "Download \(files.count) Items…")) { window.download(files) })
                menu.addItem(ClosureMenuItem(files.count == 1 ? String(localized: "Copy Path") : String(localized: "Copy Paths")) { window.copyPaths(files) })
            }
            let tools = NSMenu()
            for tool in window.toolFiles {
                tools.addItem(ClosureMenuItem(tool.lastPathComponent) { window.upload([tool], to: self.shownPath) })
            }
            if !tools.items.isEmpty { tools.addItem(.separator()) }
            tools.addItem(ClosureMenuItem(String(localized: "Choose Tools Folder…")) { window.chooseToolsFolder() })
            menu.addItem(submenu("Upload Tool", tools))

            if let single {
                menu.addItem(.separator())
                if single.isDirectory {
                    menu.addItem(ClosureMenuItem(String(localized: "Open Locally")) { window.openLocally(single) })
                } else {
                    let defaultApp = window.defaultApp(for: single)
                    menu.addItem(ClosureMenuItem(defaultApp.map { "Open with \(window.appName($0))" } ?? "Open Locally") {
                        window.openLocally(single)
                    })
                    let others = NSMenu()
                    for app in window.otherApps(for: single) {
                        let item = ClosureMenuItem(window.appName(app)) { window.openLocally(single, with: app) }
                        item.image = NSWorkspace.shared.icon(forFile: app.path)
                        item.image?.size = NSSize(width: 16, height: 16)
                        others.addItem(item)
                    }
                    if !others.items.isEmpty { others.addItem(.separator()) }
                    others.addItem(ClosureMenuItem(String(localized: "Other…")) { window.chooseApp(for: single) })
                    menu.addItem(submenu("Open With", others))
                }
            }

            menu.addItem(.separator())
            if let single {
                menu.addItem(ClosureMenuItem(connection.isPinned(single.path) ? String(localized: "Unpin") : String(localized: "Pin")) { window.togglePin(single) })
                menu.addItem(ClosureMenuItem(String(localized: "Information…")) { window.infoFile = single })
            }
            menu.addItem(ClosureMenuItem(String(localized: "Upload…")) { window.chooseUploads() })
            menu.addItem(ClosureMenuItem(String(localized: "Refresh")) { window.refresh() })
        }

        private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let file = file(at: row) else { return nil }
            let type = file.isDirectory ? UTType.folder : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
            let provider = RemoteFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.file = file
            return provider
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (provider as? RemoteFilePromiseProvider)?.file?.name ?? "download"
        }

        /// Called when the drop lands, e.g. in Finder: only now is the file
        /// downloaded, through the transfer queue.
        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let file = (provider as? RemoteFilePromiseProvider)?.file else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            nonisolated(unsafe) let done = completionHandler
            Task { @MainActor in
                guard let session = connection?.session else { return done(RemoteError.notConnected) }
                do {
                    try await session.download(file, to: url)
                    done(nil)
                } catch {
                    done(error)
                }
            }
        }

        // MARK: Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            // Onto a folder row: into that folder. Anywhere else: here.
            var target = shownPath
            if operation == .on, rows.indices.contains(row), rows[row].isDirectory {
                target = rows[row].path
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }

            if let paths = internalPaths(info) {
                let valid = paths.allSatisfy { remoteParent($0) != target && $0 != target && !target.hasPrefix($0 + "/") }
                return valid ? .move : []
            }
            return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let target = row >= 0 && rows.indices.contains(row) && rows[row].isDirectory ? rows[row].path : shownPath
            if let paths = internalPaths(info) {
                window?.move(paths, to: target)
                return true
            }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            window?.upload(urls, to: target)
            return !urls.isEmpty
        }

        /// Paths dragged from this list. Drags from other windows (another
        /// server, maybe) don't count; those arrive as file promises.
        private func internalPaths(_ info: any NSDraggingInfo) -> [String]? {
            guard (info.draggingSource as? NSTableView) === table else { return nil }
            let paths = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .remotePath) } ?? []
            return paths.isEmpty ? nil : paths
        }
    }
}

// MARK: - Pieces

/// The table, with the Linux app's keys: Return opens, Backspace or ⌘↑ goes
/// up, ⌘⌫ or Delete deletes, F2 renames; and Finder's Space for Quick Look.
final class FileTableView: NSTableView, @preconcurrency QLPreviewPanelDataSource {
    enum Key { case open, up, delete, rename, quickLook }
    var keyHandler: ((Key) -> Bool)?
    /// Local copies of the selected files, shown in the Quick Look panel.
    var previewItems: [URL] = []

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index] as NSURL
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let key: Key? = switch event.keyCode {
        case 36, 76: .open                          // Return, keypad Enter
        case 125 where command: .open                // ⌘↓
        case 126 where command: .up                  // ⌘↑
        case 51 where command: .delete               // ⌘⌫
        case 51: .up                                 // ⌫
        case 117: .delete                            // ⌦
        case 120: .rename                            // F2
        case 49: .quickLook                          // Space
        default: nil
        }
        if let key, keyHandler?(key) == true { return }
        super.keyDown(with: event)
    }
}

final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    var file: RemoteFile?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.remotePath]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .remotePath ? file?.path : super.pasteboardPropertyList(forType: type)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

final class FileCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let column: FileTable.Column

    init(column: FileTable.Column) {
        self.column = column
        super.init(frame: .zero)
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = column == .size ? .right : .left
        if column != .name { label.textColor = .secondaryLabelColor }
        addSubview(label)
        textField = label

        if column == .name {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, icon image: NSImage? = nil, secondary: Bool = false, monospaced: Bool = false) {
        label.stringValue = text
        label.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        if column == .name { label.textColor = secondary ? .secondaryLabelColor : .labelColor }
        icon.image = image
    }
}

/// Finder's icons for each file type, cached per extension.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    /// Finder's folder, without its blue: grey sits better in the sidebar.
    static let folder = desaturated(NSWorkspace.shared.icon(for: .folder))
    static let parent = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder")!

    static func icon(for file: RemoteFile) -> NSImage {
        if file.isDirectory { return folder }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }

    /// A greyscale version, drawn at whatever size and resolution it's
    /// asked for: the icon, grey blended in "saturation" mode (keeping only
    /// its lightness), then trimmed back to the icon's own shape.
    private static func desaturated(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            icon.draw(in: rect)
            context.setBlendMode(.saturation)
            context.setFillColor(NSColor.gray.cgColor)
            context.fill(rect)
            icon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            context.endTransparencyLayer()
            return true
        }
    }
}
