// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import EdithEditor
import SwiftUI

/// The main area while connected: tabs, the open file, and the status bar.
/// With no file open, recent files to pick up where you left off.
struct EditorArea: View {
    let connection: Connection
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    private var editor: EditorController { connection.editor }

    var body: some View {
        Group {
            if let tab = editor.selected {
                VStack(spacing: 0) {
                    TabStrip(editor: editor)
                    Divider()
                    TabContent(tab: tab)
                    Divider()
                    StatusBar(tab: tab)
                }
            } else {
                ConnectedWelcome(connection: connection)
            }
        }
        .onAppear(perform: applyPreferences)
        .onChange(of: app.editorPreferences) { applyPreferences() }
        .onChange(of: colorScheme) { applyPreferences() }
    }

    private func applyPreferences() {
        editor.apply(app.editorPreferences.configuration(dark: colorScheme == .dark))
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    let editor: EditorController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(editor.orderedTabs) { tab in
                        TabButton(tab: tab, editor: editor, selected: tab === editor.selected)
                            .id(tab.id)
                        Divider().frame(height: 18)
                    }
                }
            }
            .onChange(of: editor.workspace.selectedPath) { _, path in
                if let path { withAnimation { proxy.scrollTo(path) } }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }
}

private struct TabButton: View {
    let tab: EditorTab
    let editor: EditorController
    let selected: Bool
    @Environment(WindowModel.self) private var window
    @State private var hovering = false

    var body: some View {
        let doc = tab.document
        HStack(spacing: 6) {
            Text(doc.isDeleted ? "\(doc.name) (Deleted)" : doc.name)
                .strikethrough(doc.isDeleted)
                .lineLimit(1)
            ZStack {
                // A dot for unsaved changes, turning into × on hover.
                if doc.isModified && !hovering {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                } else {
                    Button("Close", systemImage: "xmark") { Task { await editor.close(tab) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                        .opacity(hovering || selected ? 1 : 0)
                }
            }
            .frame(width: 14, height: 14)
        }
        .font(.callout)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { editor.select(tab) }
        .onHover { hovering = $0 }
        .help(doc.remotePath)
        .contextMenu {
            Button("Show in Sidebar") { window.reveal(doc.remotePath) }
            Button(window.connection?.isPinned(doc.remotePath) == true ? "Unpin" : "Pin") {
                window.togglePin(RemoteFile(name: doc.name, path: doc.remotePath))
            }
            Button("Copy Path") { window.copyPaths([RemoteFile(name: doc.name, path: doc.remotePath)]) }
            Divider()
            Button("Close") { Task { await editor.close(tab) } }
            Button("Close Others") { Task { await editor.closeOthers(than: tab) } }
            Button("Close to the Right") { Task { await editor.closeToRight(of: tab) } }
        }
    }
}

// MARK: - Content

private struct TabContent: View {
    let tab: EditorTab

    var body: some View {
        Group {
            if tab.document.kind == .image {
                ImageTabView(url: tab.document.localURL, revision: tab.revision)
            } else if let bridge = tab.bridge {
                if tab.isSVG {
                    HSplitView {
                        MonacoEditorView(bridge: bridge)
                            .frame(minWidth: 240, idealWidth: 640, maxWidth: .infinity)
                            .layoutPriority(1)
                        if tab.showPreview {
                            ImageTabView(url: tab.document.localURL, revision: tab.revision, showsInfo: false)
                                .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Toggle("Preview", systemImage: "eye", isOn: Binding(get: { tab.showPreview }, set: { tab.showPreview = $0 }))
                            .toggleStyle(.button)
                            .labelStyle(.iconOnly)
                            .help(tab.showPreview ? "Hide the preview" : "Show the preview (updates on save)")
                            .padding(8)
                    }
                } else {
                    MonacoEditorView(bridge: bridge)
                }
            }
        }
        // A new tab means a different web view; don't reuse the old one.
        .id(tab.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An image, scaled down to fit, on a checkerboard for transparency, with
/// its size and dimensions underneath.
struct ImageTabView: View {
    let url: URL
    let revision: Int
    var showsInfo = true

    var body: some View {
        let image = NSImage(contentsOf: url)
        VStack(spacing: 0) {
            ZStack {
                Checkerboard()
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(20)
                } else {
                    ContentUnavailableView("Can't Show This Image", systemImage: "photo",
                                           description: Text(url.pathExtension.lowercased() == "svg" ? "The SVG may have an error. The preview updates when you save." : ""))
                }
            }
            if showsInfo, let image {
                Divider()
                Text(info(image))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .id(revision)
    }

    private func info(_ image: NSImage) -> String {
        let pixels = image.representations.first.map { "\($0.pixelsWide) × \($0.pixelsHigh) px" } ?? ""
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0).formatted(.byteCount(style: .file)) } ?? ""
        return [pixels, url.pathExtension.uppercased(), bytes].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0...Int(size.height / cell) {
                for col in 0...Int(size.width / cell) where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.12)))
                }
            }
        }
    }
}

// MARK: - Status bar

/// Cursor, wrap, language, indentation and line endings of the open file,
/// each one clickable to change it.
private struct StatusBar: View {
    let tab: EditorTab
    @State private var pickingLanguage = false
    @State private var pickingIndent = false
    @State private var pickingLineEnding = false

    var body: some View {
        HStack(spacing: 14) {
            if tab.document.isSaving {
                ProgressView().controlSize(.mini)
                Text("Saving…").foregroundStyle(.secondary)
            }
            Spacer()
            if let bridge = tab.bridge {
                Button("Ln \(tab.line), Col \(tab.column)") { bridge.gotoLine() }
                    .help("Go to line (⌘L)")
                Button(tab.wordWrap ? "Wrap" : "No Wrap") { bridge.toggleWrap() }
                    .help("Toggle word wrap (⌥Z)")
                Button(MonacoCatalog.languageName(tab.language)) { pickingLanguage = true }
                    .help("Change syntax highlighting")
                    .popover(isPresented: $pickingLanguage, arrowEdge: .top) {
                        LanguagePicker(current: tab.language) { id in
                            tab.language = id
                            bridge.setLanguage(id)
                            pickingLanguage = false
                        }
                    }
                Button(tab.insertSpaces ? "Spaces: \(tab.tabSize)" : "Tab: \(tab.tabSize)") { pickingIndent = true }
                    .help("Change indentation")
                    .popover(isPresented: $pickingIndent, arrowEdge: .top) {
                        Form {
                            Picker("Indent Using", selection: indentBinding(bridge, \.insertSpaces)) {
                                Text("Spaces").tag(true)
                                Text("Tabs").tag(false)
                            }
                            .pickerStyle(.radioGroup)
                            Picker("Width", selection: indentBinding(bridge, \.tabSize)) {
                                ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding()
                        .frame(width: 240)
                    }
                Button(tab.lineEnding.uppercased()) { pickingLineEnding = true }
                    .help("Change line endings")
                    .popover(isPresented: $pickingLineEnding, arrowEdge: .top) {
                        Picker("Line Endings", selection: Binding(get: { tab.lineEnding }, set: { setLineEnding($0, bridge) })) {
                            Text("LF (Unix, macOS)").tag("lf")
                            Text("CRLF (Windows)").tag("crlf")
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .padding()
                    }
                Text(tab.document.hasBOM ? "UTF-8 BOM" : tab.document.encoding.displayName)
                    .foregroundStyle(.secondary)
                    .help("The file is saved in the encoding it was read in.")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func indentBinding<T>(_ bridge: EditorBridge, _ keyPath: ReferenceWritableKeyPath<EditorTab, T>) -> Binding<T> {
        Binding(get: { tab[keyPath: keyPath] }, set: { value in
            tab[keyPath: keyPath] = value
            bridge.setIndent(insertSpaces: tab.insertSpaces, tabSize: tab.tabSize)
        })
    }

    private func setLineEnding(_ eol: String, _ bridge: EditorBridge) {
        tab.lineEnding = eol
        bridge.setLineEnding(eol)
        pickingLineEnding = false
    }
}

private struct LanguagePicker: View {
    let current: String
    let pick: (String) -> Void
    @State private var filter = ""

    var body: some View {
        let all = [MonacoCatalog.plainText] + MonacoCatalog.languages
        let shown = filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.id.contains(filter.lowercased()) }
        VStack(spacing: 0) {
            TextField("Filter", text: $filter, prompt: Text("Filter…"))
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onSubmit { if let first = shown.first { pick(first.id) } }
            List(shown) { entry in
                Button {
                    pick(entry.id)
                } label: {
                    HStack {
                        Text(entry.name)
                        Spacer()
                        if entry.id == current { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 240, height: 340)
    }
}

// MARK: - Nothing open

private struct ConnectedWelcome: View {
    let connection: Connection
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Connected to \(connection.server.host)")
                .font(.title.weight(.semibold))
            if connection.recents.isEmpty {
                Text("Open a file from the sidebar to edit it.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(connection.recents, id: \.self) { path in
                        Button {
                            window.openFile(at: path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remoteName(path)).fontWeight(.medium)
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Show in Sidebar") { window.reveal(path) }
                            Button("Remove from Recents") {
                                try? window.app.config.deleteRecent(serverID: connection.server.id, path: path)
                                connection.reloadRecents()
                            }
                        }
                        if path != connection.recents.last { Divider() }
                    }
                }
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
