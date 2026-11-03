// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import SwiftUI

/// One Edith window. Disconnected, the sidebar holds server groups and the
/// main area the servers. Connected, the file browser takes over the sidebar
/// and the main area is for editing, as in the Linux app.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var window: WindowModel?

    var body: some View {
        Group {
            if let window {
                WindowContent(window: window)
            }
        }
        .task {
            if window == nil { window = WindowModel(app: app) }
        }
    }
}

private struct WindowContent: View {
    @Bindable var window: WindowModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // Connected, the breadcrumbs say where you are; a title would repeat them.
        .navigationTitle(window.connection == nil ? title : "")
        .toolbar { toolbar }
        .focusedSceneValue(\.windowModel, window)
        .sheet(item: $window.serverEditor) { ServerEditor(request: $0) }
        .sheet(item: $window.secretRequest) { SecretPrompt(request: $0) }
        .sheet(item: $window.hostKeyRequest) { HostKeyPrompt(request: $0) }
        .sheet(item: $window.passphraseRequest) { PassphrasePrompt(request: $0) }
        .sheet(item: $window.nameRequest) { NamePrompt(request: $0) }
        .sheet(item: $window.infoFile) { FileInfoSheet(file: $0) }
        .sheet(item: $window.folderChoice) { FolderChooser(choice: $0) }
        .alert(window.confirmation?.title ?? "", isPresented: isPresented($window.confirmation), presenting: window.confirmation) { c in
            Button(c.action, role: c.destructive ? .destructive : nil) { Task { await c.perform() } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
        .alert(window.choice?.title ?? "", isPresented: isPresented($window.choice), presenting: window.choice) { c in
            ForEach(Array(c.options.enumerated()), id: \.offset) { index, option in
                Button(option.title, role: option.role) { c.answer(index) }
            }
            Button("Cancel", role: .cancel) { c.answer(nil) }
        } message: { c in
            Text(c.message)
        }
        .alert(window.message?.title ?? "", isPresented: isPresented($window.message), presenting: window.message) { _ in
            Button("OK") {}
        } message: { m in
            Text(m.text)
        }
        .environment(window)
        .onDisappear { window.forceDisconnect() }
        .background(WindowAccessor { window.attach($0) })
        .onChange(of: window.hasUnsavedChanges) { _, unsaved in window.hostWindow?.isDocumentEdited = unsaved }
        .onChange(of: window.showFileDetails) { _, show in window.fitSidebar(toDetails: show) }
        .debugHooks(window)
    }

    /// Presents while the optional is set; dismissing clears it.
    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    @ViewBuilder private var sidebar: some View {
        if let connection = window.connection {
            FileSidebar(connection: connection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 1200)
        } else {
            ServerSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        }
    }

    @ViewBuilder private var detail: some View {
        switch window.phase {
        case .disconnected:
            ServerListView()
        case .connecting(let server):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(server.displayName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected(let connection):
            EditorArea(connection: connection)
        }
    }

    private var title: String {
        switch window.phase {
        case .disconnected: "Edith"
        case .connecting(let server): server.displayName
        case .connected(let connection): connection.server.displayName
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let connection = window.connection {
            ToolbarItem(placement: .navigation) {
                Button("Disconnect", systemImage: "eject") { window.disconnect() }
                    .help("Disconnect (⌘D)")
            }
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") { Task { await connection.browser.goBack() } }
                        .disabled(!connection.browser.canGoBack)
                    Button("Forward", systemImage: "chevron.right") { Task { await connection.browser.goForward() } }
                        .disabled(!connection.browser.canGoForward)
                }
                .controlGroupStyle(.navigation)
            }
            ToolbarItem(placement: .principal) {
                PathBar(browser: connection.browser)
            }
            ToolbarItem(placement: .primaryAction) {
                TransferButton(log: connection.transfers)
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button("Connect", systemImage: "bolt.horizontal") {
                    if let server = window.selectedServer { window.connect(server) }
                }
                .help("Connect to the selected server")
                .disabled(window.selectedServer == nil || !window.isDisconnected)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Group", systemImage: "folder.badge.plus") { window.newGroup() }
                    .help("New server group")
                Button("Add Server", systemImage: "plus") { window.addServer() }
                    .help("Add a server (⌘N)")
            }
        }
    }
}

/// Hands over the NSWindow a SwiftUI view ends up in.
struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { found(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
