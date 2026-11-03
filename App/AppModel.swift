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
    let certificates: CertificateStore

    private(set) var servers: [Server] = []
    private(set) var folders: [Folder] = []
    private(set) var pinnedServerIDs: [String] = []
    private(set) var editorPreferences = EditorPreferences()
    @ObservationIgnored private var windows: [WeakWindow] = []
    @ObservationIgnored private var sessionRestored = false
    @ObservationIgnored private let sessionKey: String

    private struct WeakWindow {
        weak var model: WindowModel?
    }

    /// `EDITH_CONFIG_DIR` points the app at another settings folder, with its
    /// own known_hosts and Keychain service, for trying things out without
    /// touching the real configuration.
    /// No settings file existed at launch: a fresh install.
    let isFirstRun: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dir = environment["EDITH_CONFIG_DIR"] {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            config = ConfigStore(fileURL: url.appending(path: "servers.json"))
            hostKeys = HostKeyStore(appFile: url.appending(path: "known_hosts"))
            certificates = CertificateStore(fileURL: url.appending(path: "trusted_certificates.json"))
            keychain = Keychain(service: Keychain.defaultService + ".dev")
        } else {
            config = ConfigStore()
            hostKeys = HostKeyStore()
            certificates = CertificateStore()
            keychain = Keychain()
        }
        sessionKey = environment["EDITH_CONFIG_DIR"] == nil ? "lastSession" : "lastSession.dev"
        isFirstRun = !config.exists
        config.backupNow()
        reload()
        editorPreferences = EditorPreferences.load(from: config)
    }

    /// Whether this launch is the first on a new version, recording that it
    /// was seen. A fresh install has nothing new to report.
    func shouldShowWhatsNew(version: String) -> Bool {
        let key = "mac_whats_new_seen"
        let seen: String? = config.preference(key)
        guard seen != version else { return false }
        try? config.setPreference(key, version)
        return !isFirstRun && !WhatsNewView.notes.isEmpty
    }

    func setEditorPreferences(_ new: EditorPreferences) throws {
        let old = editorPreferences
        editorPreferences = new
        try new.save(to: config, replacing: old)
    }

    // MARK: Last session

    /// Where a window was: kept in the app's defaults rather than
    /// servers.json, which would otherwise be rewritten on every click.
    struct LastSession: Codable, Equatable {
        var serverID: String
        var path: String
        var tabs: [String]
    }

    func rememberSession(_ session: LastSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
    }

    /// The session to restore, once per launch, if that's switched on and
    /// the server still exists.
    func takeSessionToRestore() -> (LastSession, Server)? {
        guard !sessionRestored, editorPreferences.restoreSession else { return nil }
        sessionRestored = true
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(LastSession.self, from: data),
              let server = server(id: session.serverID)
        else { return nil }
        return (session, server)
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

    /// Every saved password, by server id, for an export. Off the main
    /// thread: a few hundred Keychain reads take a moment.
    func collectSecrets() async -> [String: String] {
        let keychain = keychain
        let ids = servers.map(\.id)
        return await Task.detached {
            var found: [String: String] = [:]
            for id in ids { if let secret = try? keychain.secret(for: id) { found[id] = secret } }
            return found
        }.value
    }

    func savePasswords(_ passwords: [String: String]) throws {
        for (id, password) in passwords { try keychain.setSecret(password, for: id) }
    }

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
