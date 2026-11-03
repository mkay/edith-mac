// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import Foundation
import Observation

/// State shared by every window: the saved servers and groups, and where
/// secrets and host keys live.
@MainActor
@Observable
final class AppModel {
    let config: ConfigStore
    let keychain: Keychain
    let hostKeys: HostKeyStore

    private(set) var servers: [Server] = []
    private(set) var folders: [Folder] = []
    private(set) var pinnedServerIDs: [String] = []
    private(set) var editorPreferences = EditorPreferences()
    @ObservationIgnored private var windows: [WeakWindow] = []

    private struct WeakWindow {
        weak var model: WindowModel?
    }

    /// `EDITH_CONFIG_DIR` points the app at another settings folder, with its
    /// own known_hosts and Keychain service, for trying things out without
    /// touching the real configuration.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dir = environment["EDITH_CONFIG_DIR"] {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            config = ConfigStore(fileURL: url.appending(path: "servers.json"))
            hostKeys = HostKeyStore(appFile: url.appending(path: "known_hosts"))
            keychain = Keychain(service: Keychain.defaultService + ".dev")
        } else {
            config = ConfigStore()
            hostKeys = HostKeyStore()
            keychain = Keychain()
        }
        config.backupNow()
        reload()
        editorPreferences = EditorPreferences.load(from: config)
    }

    func setEditorPreferences(_ new: EditorPreferences) throws {
        let old = editorPreferences
        editorPreferences = new
        try new.save(to: config, replacing: old)
    }

    // MARK: Windows

    func register(_ window: WindowModel) {
        windows.removeAll { $0.model == nil }
        windows.append(WeakWindow(model: window))
    }

    /// Unsaved tabs in any window, by server, for the quit warning.
    var unsavedSummary: [String] {
        windows.compactMap(\.model).compactMap { window in
            guard let c = window.connection, c.editor.hasUnsavedChanges else { return nil }
            let names = c.editor.orderedTabs.filter { $0.document.isModified || $0.document.isDeleted }.map(\.document.name)
            return "\(c.server.displayName): \(names.joined(separator: ", "))"
        }
    }

    func reload() {
        servers = config.servers()
        folders = config.folders()
        pinnedServerIDs = config.pinnedServers()
    }

    private func change(_ body: () throws -> Void) throws {
        defer { reload() }
        try body()
    }

    // MARK: Servers

    func server(id: String) -> Server? {
        servers.first { $0.id == id }
    }

    /// Adds or updates a server. `secret` replaces the saved password or
    /// passphrase; an empty string removes it; nil leaves it alone.
    func save(_ server: Server, secret: String?) throws {
        try change {
            if servers.contains(where: { $0.id == server.id }) {
                try config.updateServer(server)
            } else {
                try config.addServer(server)
            }
        }
        if let secret {
            if secret.isEmpty {
                try keychain.deleteSecret(for: server.id)
            } else {
                try keychain.setSecret(secret, for: server.id)
            }
        }
    }

    func delete(_ server: Server) throws {
        try change { try config.deleteServer(id: server.id) }
        try? keychain.deleteSecret(for: server.id)
        if pinnedServerIDs.contains(server.id) { try? change { try config.toggleServerPin(server.id) } }
    }

    /// A copy under a new id, with the same saved secret.
    @discardableResult
    func duplicate(_ server: Server) throws -> Server {
        var copy = server
        copy.id = UUID().uuidString.lowercased()
        copy.name = "\(server.displayName) copy"
        try save(copy, secret: try keychain.secret(for: server.id))
        return copy
    }

    func move(_ server: Server, toFolder folderID: String) throws {
        try change { try config.moveServer(id: server.id, toFolder: folderID) }
    }

    func togglePin(_ server: Server) throws {
        try change { try config.toggleServerPin(server.id) }
    }

    func secret(for server: Server) -> String? {
        try? keychain.secret(for: server.id)
    }

    // MARK: Groups

    @discardableResult
    func addFolder(named name: String) throws -> Folder {
        let folder = Folder(name: name)
        try change { try config.addFolder(folder) }
        return folder
    }

    func rename(_ folder: Folder, to name: String) throws {
        var renamed = folder
        renamed.name = name
        try change { try config.updateFolder(renamed) }
    }

    /// Deletes a group; its servers become ungrouped.
    func delete(_ folder: Folder) throws {
        try change {
            let servers = config.servers().map { s in
                var s = s
                if s.folderID == folder.id { s.folderID = "" }
                return s
            }
            try config.saveAll(servers: servers, folders: config.folders().filter { $0.id != folder.id })
        }
    }

    func moveFolders(from source: IndexSet, to destination: Int) throws {
        var ids = folders.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        try change { try config.reorderFolders(ids) }
    }

    // MARK: Import

    func importServers(_ file: ServerFile) throws -> ImportResult {
        var result = ImportResult()
        try change { result = try config.importServers(file.servers, folders: file.folders) }
        return result
    }

    /// Decrypts an export's passwords and saves those for `serverIDs` to
    /// the Keychain, off the main thread: scrypt takes about 100 ms, and a
    /// few hundred Keychain writes add up. Returns how many were saved.
    func restoreSecrets(_ blob: SecretsBlob, passphrase: String, for serverIDs: Set<String>) async throws -> Int {
        let keychain = keychain
        return try await Task.detached {
            let secrets = try blob.decrypt(passphrase: passphrase).filter { serverIDs.contains($0.key) }
            for (id, secret) in secrets { try keychain.setSecret(secret, for: id) }
            return secrets.count
        }.value
    }

    // MARK: Pins

    func pins(for server: Server) -> [Pin] {
        config.pins(serverID: server.id)
    }
}
