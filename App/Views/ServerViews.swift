// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import SwiftUI

// MARK: - Sidebar: groups

/// All Servers, Without Group, then the groups in their saved order, each
/// with a count. Servers dragged onto a group move into it.
struct ServerSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        List(selection: $window.groupSelection) {
            Label("All Servers", systemImage: "square.grid.2x2")
                .badge(app.servers.count)
                .tag(ServerGroupSelection.all)
                .dropDestination(for: String.self) { ids, _ in move(ids, to: "") }
            Label("Without Group", systemImage: "tray")
                .badge(app.servers.filter { $0.folderID.isEmpty }.count)
                .tag(ServerGroupSelection.ungrouped)
                .dropDestination(for: String.self) { ids, _ in move(ids, to: "") }

            Section("Groups") {
                ForEach(app.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(app.servers.filter { $0.folderID == folder.id }.count)
                        .tag(ServerGroupSelection.folder(folder.id))
                        .dropDestination(for: String.self) { ids, _ in move(ids, to: folder.id) }
                        .contextMenu {
                            Button("Add Server Here…") { window.addServer(inFolder: folder.id) }
                            Divider()
                            Button("Rename Group…") { window.rename(folder) }
                            Button("Delete Group…", role: .destructive) { window.confirmDelete(folder) }
                        }
                }
                .onMove { from, to in try? app.moveFolders(from: from, to: to) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusLine(text: String(localized: "Disconnected"), systemImage: "bolt.horizontal.circle", active: false)
        }
    }

    private func move(_ ids: [String], to folderID: String) -> Bool {
        for id in ids {
            if let server = app.server(id: id) { try? app.move(server, toFolder: folderID) }
        }
        return !ids.isEmpty
    }
}

/// The connection status at the bottom of the sidebar.
struct StatusLine: View {
    let text: String
    let systemImage: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(active ? Color.green : Color.secondary)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Server list

/// The servers for the selected group, in sections when showing them all.
/// Pinned servers come first. Double-click or Return connects.
struct ServerListView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    private struct Section: Identifiable {
        let id: String
        let title: String
        let servers: [Server]
    }

    var body: some View {
        @Bindable var window = window
        Group {
            if app.servers.isEmpty {
                WelcomeView()
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: window.search)
            } else {
                List(selection: $window.selectedServerIDs) {
                    ForEach(sections) { section in
                        SwiftUI.Section(section.title) {
                            ForEach(section.servers) { server in
                                ServerRow(server: server, pinned: app.pinnedServerIDs.contains(server.id))
                                    .tag(server.id)
                                    .draggable(server.id)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, ids.count == 1, let server = app.server(id: id) {
                        menu(for: server)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let server = app.server(id: id) { window.connect(server) }
                }
            }
        }
        .searchable(text: $window.search, placement: .toolbar, prompt: "Search servers")
        .navigationTitle(groupTitle)
    }

    @ViewBuilder private func menu(for server: Server) -> some View {
        Button("Connect") { window.connect(server) }
            .disabled(!window.isDisconnected)
        Divider()
        Button("Edit…") { window.edit(server) }
        Button("Duplicate") { window.duplicate(server) }
        Menu("Move to Group") {
            Button("No Group") { try? app.move(server, toFolder: "") }
                .disabled(server.folderID.isEmpty)
            Divider()
            ForEach(app.folders) { folder in
                Button(folder.name) { try? app.move(server, toFolder: folder.id) }
                    .disabled(server.folderID == folder.id)
            }
        }
        Button(app.pinnedServerIDs.contains(server.id) ? String(localized: "Unpin") : String(localized: "Pin")) { try? app.togglePin(server) }
        Divider()
        Button("Delete…", role: .destructive) { window.confirmDelete(server) }
    }

    private var groupTitle: String {
        switch window.groupSelection {
        case .all: "All Servers"
        case .ungrouped: "Without Group"
        case .folder(let id): app.folders.first { $0.id == id }?.name ?? "Servers"
        }
    }

    private var sections: [Section] {
        let query = window.search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = app.servers.filter { s in
            query.isEmpty || [s.displayName, s.host, s.username].contains { $0.lowercased().contains(query) }
        }
        let byName = { (a: Server, b: Server) in a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending }

        switch window.groupSelection {
        case .ungrouped:
            let servers = matching.filter { $0.folderID.isEmpty }.sorted(by: byName)
            return servers.isEmpty ? [] : [Section(id: "ungrouped", title: String(localized: "Without Group"), servers: servers)]
        case .folder(let id):
            let servers = matching.filter { $0.folderID == id }.sorted(by: byName)
            return servers.isEmpty ? [] : [Section(id: id, title: groupTitle, servers: servers)]
        case .all:
            var result: [Section] = []
            let pinned = matching.filter { app.pinnedServerIDs.contains($0.id) }.sorted(by: byName)
            if !pinned.isEmpty { result.append(Section(id: "pinned", title: String(localized: "Pinned"), servers: pinned)) }
            let rest = matching.filter { !app.pinnedServerIDs.contains($0.id) }
            for folder in app.folders {
                let servers = rest.filter { $0.folderID == folder.id }.sorted(by: byName)
                if !servers.isEmpty { result.append(Section(id: folder.id, title: folder.name, servers: servers)) }
            }
            // Servers in no group, or in one that no longer exists.
            let known = Set(app.folders.map(\.id))
            let loose = rest.filter { $0.folderID.isEmpty || !known.contains($0.folderID) }.sorted(by: byName)
            if !loose.isEmpty { result.append(Section(id: "ungrouped", title: String(localized: "Without Group"), servers: loose)) }
            return result
        }
    }
}

struct ServerRow: View {
    let server: Server
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(server.displayName).fontWeight(.semibold)
                ProtocolBadge(server: server)
                if pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// SFTP, FTP or FTP/TLS, coloured as in the Linux app.
struct ProtocolBadge: View {
    let server: Server

    var body: some View {
        let (label, color): (String, Color) = switch (server.serverProtocol, server.ftpEncryption) {
        case (.sftp, _): ("SFTP", .green)
        case (.ftp, .none): ("FTP", .orange)
        case (.ftp, _): ("FTP/TLS", .blue)
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct WelcomeView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Edith", systemImage: "server.rack")
        } description: {
            Text("No servers configured yet.\nAdd a server to get started, or import the list from the Linux app.")
        } actions: {
            Button("Add Your First Server") { window.addServer() }
                .buttonStyle(.borderedProminent)
            Button("Import Servers…") { window.importServers() }
        }
    }
}
