// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import Foundation
import Observation
import SwiftUI

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
    let editor: EditorController
    private(set) var pins: [Pin] = []
    private(set) var recents: [String] = []
    private let app: AppModel

    init(session: Session, app: AppModel, window: WindowModel) {
        self.session = session
        self.browser = Browser(session: session)
        self.transfers = TransferLog(queue: session.transfers)
        self.editor = EditorController(workspace: Workspace(session: session), app: app, window: window)
        self.app = app
        reloadPins()
        reloadRecents()
    }

    func reloadRecents() {
        recents = app.config.recents(serverID: server.id)
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

/// The passphrase protecting the passwords in a server export.
struct PassphraseRequest: Identifiable {
    let id = UUID()
    let error: String?
    let answer: (String?) -> Void
}

struct CertificateRequest: Identifiable {
    let id = UUID()
    let challenge: CertificateChallenge
    let answer: (Bool) -> Void
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

/// A question with several answers. Cancel is always offered and answers nil.
struct ChoiceRequest: Identifiable {
    struct Option {
        let title: String
        var role: ButtonRole?

        init(_ title: String, role: ButtonRole? = nil) {
            self.title = title
            self.role = role
        }
    }

    let id = UUID()
    let title: String
    let message: String
    let options: [Option]
    let answer: (Int?) -> Void
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
    var passphraseRequest: PassphraseRequest?
    var hostKeyRequest: HostKeyRequest?
    var certificateRequest: CertificateRequest?
    var nameRequest: NameRequest?
    var infoFile: RemoteFile?
    var folderChoice: FolderChoice?
    var confirmation: Confirmation?
    var choice: ChoiceRequest?
    var message: Message?
    var showTransfers = false

    /// The AppKit window, for what SwiftUI can't do: resizing the sidebar,
    /// and asking before a window with unsaved changes closes.
    @ObservationIgnored private(set) weak var hostWindow: NSWindow?
    @ObservationIgnored private var closeGuard: WindowCloseGuard?

    func attach(_ window: NSWindow) {
        hostWindow = window
        if closeGuard == nil {
            closeGuard = WindowCloseGuard(window: window) { [weak self] in self?.windowShouldClose() ?? true }
        }
    }

    /// Lets the window close, unless tabs have unsaved changes: then asks,
    /// and closes it afterwards if the answer is to discard them.
    private func windowShouldClose() -> Bool {
        guard hasUnsavedChanges else { return true }
        Task {
            let answer = await choose(
                title: "Close Window with Unsaved Changes?",
                message: "Your unsaved changes will be lost.",
                buttons: [.init("Discard and Close", role: .destructive)]
            )
            if answer == 0 {
                forceDisconnect()
                hostWindow?.close()
            }
        }
        return false
    }
    @ObservationIgnored private var sidebarWidthBeforeDetails: CGFloat?

    init(app: AppModel) {
        self.app = app
        app.register(self)
    }

    var hasUnsavedChanges: Bool { connection?.editor.hasUnsavedChanges ?? false }

    /// Asks a question with several answers; nil means Cancel.
    func choose(title: String, message: String, buttons: [ChoiceRequest.Option]) async -> Int? {
        // One question at a time: wait for any open one to be answered.
        while choice != nil { try? await Task.sleep(for: .milliseconds(100)) }
        return await withCheckedContinuation { continuation in
            choice = ChoiceRequest(title: title, message: message, options: buttons) { continuation.resume(returning: $0) }
        }
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
                    to: server, secret: secret, hostKeys: app.hostKeys, certificates: app.certificates,
                    approveHostKey: { [weak self] challenge in await self?.askHostKey(challenge) ?? false },
                    approveCertificate: { [weak self] challenge in await self?.askCertificate(challenge) ?? false }
                )
                if remember, let secret { try? app.keychain.setSecret(secret, for: server.id) }
                let connection = Connection(session: session, app: app, window: self)
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

    private func askCertificate(_ challenge: CertificateChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            certificateRequest = CertificateRequest(challenge: challenge) { continuation.resume(returning: $0) }
        }
    }

    private func askHostKey(_ challenge: HostKeyChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyRequest = HostKeyRequest(challenge: challenge) { continuation.resume(returning: $0) }
        }
    }

    /// Disconnects, asking first if any tab has unsaved changes.
    func disconnect() {
        guard let connection else { return }
        guard connection.editor.hasUnsavedChanges else { return forceDisconnect() }
        Task {
            let answer = await choose(
                title: "Disconnect with Unsaved Changes?",
                message: "Unsaved changes in: " + connection.editor.orderedTabs.filter { $0.document.isModified || $0.document.isDeleted }.map(\.document.name).joined(separator: ", "),
                buttons: [.init("Discard and Disconnect", role: .destructive)]
            )
            if answer == 0 { forceDisconnect() }
        }
    }

    func forceDisconnect() {
        guard let connection else { return }
        connection.editor.shutdown()
        hostWindow?.isDocumentEdited = false
        phase = .disconnected
        showFileDetails = false
        showTransfers = false
        Task { await connection.session.close() }
    }

    // MARK: Sidebar

    /// The detail columns need room, so turning them on widens the sidebar
    /// (as in the Linux app) and turning them off puts it back.
    /// NavigationSplitView can't set a column's width, so this moves the
    /// divider of the NSSplitView underneath it.
    func fitSidebar(toDetails show: Bool) {
        guard let split = hostWindow?.contentView.flatMap(Self.splitView(in:)),
              let sidebar = split.arrangedSubviews.first
        else { return }
        let target: CGFloat
        if show {
            sidebarWidthBeforeDetails = sidebar.frame.width
            // Leave the main area usable on narrow windows.
            target = max(sidebar.frame.width, min(720, split.bounds.width - 360))
        } else if let previous = sidebarWidthBeforeDetails {
            target = previous
            sidebarWidthBeforeDetails = nil
        } else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            split.setPosition(target, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = splitView(in: child) { return found }
        }
        return nil
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
        let file: ServerFile
        let result: ImportResult
        do {
            file = try ConfigStore.parseServerFile(url)
            result = try app.importServers(file)
        } catch {
            message = Message(title: "Can't Import", text: error.localizedDescription)
            return
        }
        var parts = ["\(result.added) added"]
        if result.updated > 0 { parts.append("\(result.updated) updated") }
        if result.foldersAdded > 0 { parts.append("\(result.foldersAdded) groups added") }
        let summary = "Servers: " + parts.joined(separator: ", ") + "."

        guard let blob = file.secrets else {
            message = Message(title: "Servers Imported", text: summary)
            return
        }
        Task { await restorePasswords(blob, for: Set(file.servers.map(\.id)), summary: summary) }
    }

    /// Asks for the export's passphrase until it's right or the user skips.
    private func restorePasswords(_ blob: SecretsBlob, for ids: Set<String>, summary: String) async {
        var error: String?
        while true {
            let passphrase: String? = await withCheckedContinuation { continuation in
                passphraseRequest = PassphraseRequest(error: error) { continuation.resume(returning: $0) }
            }
            guard let passphrase else {
                message = Message(title: "Servers Imported", text: summary + " Passwords weren't imported; you'll be asked for them when connecting.")
                return
            }
            do {
                let saved = try await app.restoreSecrets(blob, passphrase: passphrase, for: ids)
                message = Message(title: "Servers Imported", text: summary + " \(saved) passwords saved to your Keychain.")
                return
            } catch SecretsError.wrongPassphrase {
                error = "Wrong passphrase. Try again."
            } catch {
                message = Message(title: "Servers Imported, Passwords Not", text: summary + " " + error.localizedDescription)
                return
            }
        }
    }

    private static func required(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw RemoteError.failed("The name can't be empty.") }
        return trimmed
    }

    // MARK: Files

    /// Opens a folder in the browser, or a file in the editor. A binary file
    /// can't be edited, so it's offered as a download instead.
    func open(_ file: RemoteFile) {
        guard let connection else { return }
        if file.isDirectory {
            Task { await connection.browser.open(file.path) }
            return
        }
        Task {
            do {
                try await connection.editor.open(file.path)
                connection.reloadRecents()
            } catch WorkspaceError.binary(let name) {
                confirmation = Confirmation(
                    title: "Can't Edit “\(name)”",
                    message: "It looks like a binary file, which the editor can't show. Download it instead?",
                    action: "Download…", destructive: false
                ) { [self] in download([file]) }
            } catch is CancellationError {
            } catch {
                message = Message(title: "Couldn't Open “\(file.name)”", text: error.localizedDescription)
            }
        }
    }

    func openFile(at path: String) {
        open(RemoteFile(name: remoteName(path), path: path))
    }

    /// Shows a file's folder in the browser, with the file selected.
    func reveal(_ path: String) {
        navigate(to: remoteParent(path))
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
            openFile(at: pin.path)
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
