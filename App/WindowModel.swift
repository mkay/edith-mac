// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import Foundation
import Observation

/// What the server list shows, picked in the sidebar.
enum ServerGroupSelection: Hashable {
    case all
    case ungrouped
    case folder(String)
}

/// A live connection in a window.
@MainActor
@Observable
final class Connection {
    let session: Session
    let browser: Browser
    let transfers: TransferLog
    private(set) var pins: [Pin] = []
    private let app: AppModel

    init(session: Session, app: AppModel) {
        self.session = session
        self.browser = Browser(session: session)
        self.transfers = TransferLog(queue: session.transfers)
        self.app = app
        reloadPins()
    }

    var server: Server { session.server }

    func reloadPins() {
        pins = app.pins(for: server)
    }

    func isPinned(_ path: String) -> Bool {
        pins.contains { $0.path == path }
    }
}

// MARK: - Dialog requests

/// Asks for a password or passphrase when none is saved, or the saved one failed.
struct SecretRequest: Identifiable {
    let id = UUID()
    let server: Server
    let kind: Server.SecretKind
    let error: String?
    let answer: (_ secret: String?, _ remember: Bool) -> Void
}

struct HostKeyRequest: Identifiable {
    let id = UUID()
    let challenge: HostKeyChallenge
    let answer: (Bool) -> Void
}

/// A one-field name prompt: new file, new folder, rename, groups.
struct NameRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    var initial = ""
    let action: String
    let commit: (String) async throws -> Void
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    var destructive = true
    let perform: () async -> Void
}

struct FolderChoice: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    let start: String
    let choose: (String) async -> Void
}

struct Message: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ServerEditorRequest: Identifiable {
    let id = UUID()
    var server: Server
    let isNew: Bool
}

// MARK: - Window

@MainActor
@Observable
final class WindowModel {
    enum Phase {
        case disconnected
        case connecting(Server)
        case connected(Connection)
    }

    let app: AppModel
    private(set) var phase = Phase.disconnected

    // Server list
    var groupSelection = ServerGroupSelection.all
    var selectedServerIDs: Set<String> = []
    var search = ""

    // File browser
    var showFileDetails = false

    // Presentation
    var serverEditor: ServerEditorRequest?
    var secretRequest: SecretRequest?
    var hostKeyRequest: HostKeyRequest?
    var nameRequest: NameRequest?
    var infoFile: RemoteFile?
    var folderChoice: FolderChoice?
    var confirmation: Confirmation?
    var message: Message?
    var showTransfers = false

    init(app: AppModel) {
        self.app = app
    }

    var connection: Connection? {
        if case .connected(let c) = phase { c } else { nil }
    }

    var isDisconnected: Bool {
        if case .disconnected = phase { true } else { false }
    }

    var selectedServer: Server? {
        selectedServerIDs.count == 1 ? selectedServerIDs.first.flatMap(app.server(id:)) : nil
    }

    // MARK: Connecting

    func connect(_ server: Server) {
        guard isDisconnected else { return }
        Task { await connectFlow(server) }
    }

    private func connectFlow(_ server: Server) async {
        var secret = server.secretKind == .none ? nil : app.secret(for: server)
        var remember = false
        if server.secretKind != .none && secret == nil {
            guard let answer = await askSecret(server, error: nil) else { return }
            (secret, remember) = answer
        }

        phase = .connecting(server)
        while true {
            do {
                let session = try await Session.connect(
                    to: server, secret: secret, hostKeys: app.hostKeys,
                    approveHostKey: { [weak self] challenge in await self?.askHostKey(challenge) ?? false }
                )
                if remember, let secret { try? app.keychain.setSecret(secret, for: server.id) }
                let connection = Connection(session: session, app: app)
                phase = .connected(connection)
                await connection.browser.open(session.startDirectory)
                return
            } catch RemoteError.authenticationFailed(let reason) where server.secretKind != .none {
                // Wrong or missing password: ask again rather than give up.
                guard let answer = await askSecret(server, error: reason) else {
                    phase = .disconnected
                    return
                }
                (secret, remember) = answer
            } catch {
                phase = .disconnected
                message = Message(title: "Couldn't connect to \(server.displayName)", text: error.localizedDescription)
                return
            }
        }
    }

    private func askSecret(_ server: Server, error: String?) async -> (String, Bool)? {
        await withCheckedContinuation { continuation in
            secretRequest = SecretRequest(server: server, kind: server.secretKind, error: error) { secret, remember in
                continuation.resume(returning: secret.map { ($0, remember) })
            }
        }
    }

    private func askHostKey(_ challenge: HostKeyChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyRequest = HostKeyRequest(challenge: challenge) { continuation.resume(returning: $0) }
        }
    }

    func disconnect() {
        guard let connection else { return }
        phase = .disconnected
        showFileDetails = false
        showTransfers = false
        Task { await connection.session.close() }
    }

    // MARK: Servers

    func addServer(inFolder folderID: String? = nil) {
        var server = Server()
        if let folderID {
            server.folderID = folderID
        } else if case .folder(let id) = groupSelection {
            server.folderID = id
        }
        serverEditor = ServerEditorRequest(server: server, isNew: true)
    }

    func edit(_ server: Server) {
        serverEditor = ServerEditorRequest(server: server, isNew: false)
    }

    func duplicate(_ server: Server) {
        attempt { selectedServerIDs = [try self.app.duplicate(server).id] }
    }

    func confirmDelete(_ server: Server) {
        confirmation = Confirmation(
            title: "Delete Server?",
            message: "Remove “\(server.displayName)” from your servers? Its saved password is removed too.",
            action: "Delete"
        ) { [self] in attempt { try app.delete(server) } }
    }

    func newGroup() {
        nameRequest = NameRequest(title: "New Server Group", label: "Name", action: "Create") { [self] name in
            let folder = try app.addFolder(named: try Self.required(name))
            groupSelection = .folder(folder.id)
        }
    }

    func rename(_ folder: Folder) {
        nameRequest = NameRequest(title: "Rename Group", label: "Name", initial: folder.name, action: "Rename") { [self] name in
            try app.rename(folder, to: try Self.required(name))
        }
    }

    func confirmDelete(_ folder: Folder) {
        confirmation = Confirmation(
            title: "Delete Group?",
            message: "Delete “\(folder.name)”? Servers inside will become ungrouped.",
            action: "Delete"
        ) { [self] in
            attempt { try app.delete(folder) }
            if groupSelection == .folder(folder.id) { groupSelection = .all }
        }
    }

    func importServers() {
        let panel = NSOpenPanel()
        panel.title = "Import Servers"
        panel.message = "Choose an Edith export or a servers.json, for example from the Linux app (~/.config/edith/servers.json)."
        panel.allowedContentTypes = [.json]
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            let result = try app.importServers(from: url)
            var parts = ["\(result.added) added"]
            if result.updated > 0 { parts.append("\(result.updated) updated") }
            if result.foldersAdded > 0 { parts.append("\(result.foldersAdded) groups added") }
            message = Message(title: "Servers Imported", text: parts.joined(separator: ", ") + ".")
        }
    }

    private static func required(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw RemoteError.failed("The name can't be empty.") }
        return trimmed
    }

    // MARK: Files

    /// Opens a folder, or (from Phase 3) a file in the editor.
    func open(_ file: RemoteFile) {
        guard let connection else { return }
        if file.isDirectory {
            Task { await connection.browser.open(file.path) }
        } else {
            message = Message(title: "Not Yet", text: "Opening files in the editor comes in the next version of the Mac app.")
        }
    }

    func navigate(to path: String) {
        guard let connection else { return }
        Task { await connection.browser.open(path) }
    }

    func newFile() {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: "New File", label: "Name", action: "Create") { name in
            try await browser.createFile(named: name)
        }
    }

    func newFolder() {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: "New Folder", label: "Name", action: "Create") { name in
            try await browser.createFolder(named: name)
        }
    }

    func rename(_ file: RemoteFile) {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: "Rename", label: "Name", initial: file.name, action: "Rename") { name in
            try await browser.rename(file, to: name)
        }
    }

    func confirmDelete(_ files: [RemoteFile]) {
        guard let browser = connection?.browser, !files.isEmpty else { return }
        let what = files.count == 1 ? "“\(files[0].name)”" : "\(files.count) items"
        let folders = files.contains { $0.isDirectory && !$0.isSymlink }
        confirmation = Confirmation(
            title: "Delete \(what)?",
            message: (folders ? "Folders are deleted with everything in them. " : "") + "This can't be undone.",
            action: "Delete"
        ) { [self] in await attempt { try await browser.delete(files) } }
    }

    func duplicate(_ files: [RemoteFile]) {
        guard let browser = connection?.browser else { return }
        Task { await attempt { try await browser.duplicate(files) } }
    }

    func setPermissions(_ file: RemoteFile, to permissions: UInt32) {
        guard let browser = connection?.browser else { return }
        Task { await attempt { try await browser.setPermissions(file, to: permissions) } }
    }

    func chooseDestination(moving files: [RemoteFile]) {
        guard let browser = connection?.browser else { return }
        folderChoice = FolderChoice(title: "Move to", action: "Move", start: browser.path) { [self] dir in
            await attempt { try await browser.move(files, to: dir) }
        }
    }

    func chooseDestination(copying files: [RemoteFile]) {
        guard let browser = connection?.browser else { return }
        folderChoice = FolderChoice(title: "Copy to", action: "Copy", start: browser.path) { [self] dir in
            await attempt { try await browser.copy(files, to: dir) }
        }
    }

    /// Moves files dropped onto a folder in the list.
    func move(_ paths: [String], to directory: String) {
        guard let browser = connection?.browser else { return }
        let files = paths.map { path in
            browser.entries.first { $0.path == path } ?? RemoteFile(name: remoteName(path), path: path)
        }
        Task { await attempt { try await browser.move(files, to: directory) } }
    }

    func copyPaths(_ files: [RemoteFile]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func togglePin(_ file: RemoteFile) {
        guard let connection else { return }
        attempt {
            if connection.isPinned(file.path) {
                try app.config.deletePin(serverID: connection.server.id, path: file.path)
            } else {
                try app.config.addPin(serverID: connection.server.id, Pin(path: file.path, isDirectory: file.isDirectory))
            }
            connection.reloadPins()
        }
    }

    func unpin(_ pin: Pin) {
        guard let connection else { return }
        attempt {
            try app.config.deletePin(serverID: connection.server.id, path: pin.path)
            connection.reloadPins()
        }
    }

    func activate(_ pin: Pin) {
        if pin.isDirectory {
            navigate(to: pin.path)
        } else {
            open(RemoteFile(name: remoteName(pin.path), path: pin.path))
        }
    }

    func refresh() {
        guard let browser = connection?.browser else { return }
        Task { await browser.refresh() }
    }

    // MARK: Transfers

    func chooseUploads() {
        guard let connection else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, to: connection.browser.path)
    }

    /// Uploads local files and folders, asking before replacing anything.
    func upload(_ urls: [URL], to directory: String) {
        guard let connection, !urls.isEmpty else { return }
        Task {
            let existing: [String]
            do {
                existing = try await connection.session.conflicts(uploading: urls, to: directory)
            } catch {
                message = Message(title: "Upload Failed", text: error.localizedDescription)
                return
            }
            if existing.isEmpty {
                await runUpload(urls, to: directory, overwrite: false, on: connection)
            } else {
                let what = existing.count == 1 ? "“\(existing[0])” already exists" : "\(existing.count) items already exist"
                confirmation = Confirmation(
                    title: "Replace Existing Items?",
                    message: "\(what) in \(remoteName(directory)). Replacing overwrites them on the server.",
                    action: "Replace"
                ) { [self] in await runUpload(urls, to: directory, overwrite: true, on: connection) }
            }
        }
    }

    private func runUpload(_ urls: [URL], to directory: String, overwrite: Bool, on connection: Connection) async {
        do {
            try await connection.session.upload(urls, to: directory, overwrite: overwrite)
        } catch is CancellationError {
        } catch {
            message = Message(title: "Upload Failed", text: error.localizedDescription)
        }
        if connection.browser.path == directory { await connection.browser.refresh() }
    }

    func download(_ files: [RemoteFile]) {
        guard let connection, !files.isEmpty else { return }
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = files[0].name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await attempt { try await connection.session.download(files[0], to: url) } }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Download \(files.count) Items"
            panel.prompt = "Download"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await attempt { try await connection.session.download(files, into: url) } }
        }
    }

    // MARK: Errors

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { message = Message(title: "Something Went Wrong", text: error.localizedDescription) }
    }

    private func attempt(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch is CancellationError {
        } catch {
            message = Message(title: "Something Went Wrong", text: error.localizedDescription)
        }
    }
}

// MARK: - Transfer log

/// What the transfer panel shows: every job of this connection and its state.
@MainActor
@Observable
final class TransferLog {
    enum State: Equatable {
        case queued
        case running(Double?)
        case done
        case failed(String)
        case cancelled
    }

    struct Job: Identifiable {
        let id: TransferQueue.JobID
        let label: String
        var state: State

        var isFinished: Bool {
            switch state {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    private(set) var jobs: [Job] = []
    private let queue: TransferQueue

    init(queue: TransferQueue) {
        self.queue = queue
        let events = queue.events
        Task { [weak self] in
            for await event in events { self?.apply(event) }
        }
    }

    var active: Job? { jobs.first { if case .running = $0.state { true } else { false } } }
    var isBusy: Bool { jobs.contains { !$0.isFinished } }
    var hasFinished: Bool { jobs.contains(where: \.isFinished) }

    func cancel(_ id: TransferQueue.JobID) {
        Task { await queue.cancel(id) }
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
    }

    private func apply(_ event: TransferQueue.Event) {
        func update(_ id: TransferQueue.JobID, _ state: State) {
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state }
        }
        switch event {
        case .queued(let id, let label): jobs.append(Job(id: id, label: label, state: .queued))
        case .started(let id, _, _): update(id, .running(nil))
        case .progress(let id, _, let fraction, _): update(id, .running(fraction))
        case .done(let id, _): update(id, .done)
        case .failed(let id, _, let message): update(id, .failed(message))
        case .cancelled(let id, _): update(id, .cancelled)
        case .idle: break
        }
    }
}
