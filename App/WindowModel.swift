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
    /// Files opened in other apps, watched so their saves are uploaded.
    @ObservationIgnored var externalEdits: [String: FileWatcher] = [:]
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
    var exportPassphraseRequest: PassphraseRequest?
    var showSupport = false
    var showWhatsNew = false
    var hostKeyRequest: HostKeyRequest?
    var certificateRequest: CertificateRequest?
    var nameRequest: NameRequest?
    var infoFile: RemoteFile?
    var folderChoice: FolderChoice?
    var confirmation: Confirmation?
    var choice: ChoiceRequest?
    var message: Message?
    var showTransfers = false
    /// A short note in the sidebar's status line ("Uploaded index.php").
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    func announce(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// The AppKit window, for what SwiftUI can't do: resizing the sidebar,
    /// and asking before a window with unsaved changes closes.
    @ObservationIgnored private(set) weak var hostWindow: NSWindow?
    /// The width of the main area, which the breadcrumbs size themselves from.
    var detailWidth: CGFloat = 0 {
        didSet { DispatchQueue.main.async { [weak self] in self?.remeasureHiddenToolbarItems() } }
    }
    @ObservationIgnored private var closeGuard: WindowCloseGuard?

    func attach(_ window: NSWindow) {
        hostWindow = window
        // Remembers size and position; only the first window gets the name.
        window.setFrameAutosaveName("Edith")
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
                title: String(localized: "Close Window with Unsaved Changes?"),
                message: String(localized: "Your unsaved changes will be lost."),
                buttons: [.init(String(localized: "Discard and Close"), role: .destructive)]
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

    func connect(_ server: Server, then restore: AppModel.LastSession? = nil) {
        guard isDisconnected else { return }
        Task { await connectFlow(server, restoring: restore) }
    }

    /// Where this window is, for picking up there on the next launch.
    var sessionSnapshot: AppModel.LastSession? {
        guard let connection else { return nil }
        return .init(serverID: connection.server.id, path: connection.browser.path,
                     tabs: connection.editor.orderedTabs.map(\.document.remotePath))
    }

    private func connectFlow(_ server: Server, restoring restore: AppModel.LastSession? = nil) async {
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
                watchConnection(connection)
                await connection.browser.open(restore?.path ?? session.startDirectory)
                if connection.browser.error != nil, restore != nil {
                    await connection.browser.open(session.startDirectory)
                }
                // Tabs whose files are gone simply don't come back.
                for path in restore?.tabs ?? [] {
                    try? await connection.editor.open(path)
                }
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
                message = Message(title: String(localized: "Couldn't connect to \(server.displayName)"), text: error.localizedDescription)
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

    // MARK: Lost connections

    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var reconnecting: Task<Bool, Never>?

    /// Checks every two seconds whether the connection is still up, which
    /// costs no network traffic: the clients note a drop themselves.
    private func watchConnection(_ connection: Connection) {
        monitor?.cancel()
        monitor = Task { [weak self, weak connection] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let connection, !Task.isCancelled else { return }
                if await !connection.session.isConnected { _ = await ensureConnected() }
            }
        }
    }

    /// True if the connection is up, offering to reconnect first if it
    /// isn't. Open tabs and unsaved edits stay in place meanwhile, so
    /// declining only means the next action asks again.
    func ensureConnected() async -> Bool {
        guard let connection else { return false }
        if await connection.session.isConnected { return true }
        if let reconnecting { return await reconnecting.value }
        let task = Task { await offerReconnect(connection) }
        reconnecting = task
        let result = await task.value
        reconnecting = nil
        return result
    }

    private func offerReconnect(_ connection: Connection) async -> Bool {
        var failure: String?
        while true {
            let name = connection.server.displayName
            var text = String(localized: "The connection to “\(name)” was lost. Your open tabs and unsaved changes are kept.")
            if let failure { text += "\n\n" + failure }
            let answer = await choose(
                title: String(localized: "Connection Lost"),
                message: text,
                buttons: [.init(String(localized: "Reconnect")), .init(String(localized: "Disconnect"), role: .destructive)]
            )
            switch answer {
            case 0:
                do {
                    try await connection.session.reconnect()
                    await connection.browser.refresh()
                    announce(String(localized: "Reconnected"))
                    return true
                } catch {
                    failure = error.localizedDescription
                }
            case 1:
                forceDisconnect()
                return false
            default:
                return false
            }
        }
    }

    /// Disconnects, asking first if any tab has unsaved changes.
    func disconnect() {
        guard let connection else { return }
        guard connection.editor.hasUnsavedChanges else { return forceDisconnect(forgetSession: true) }
        Task {
            let answer = await choose(
                title: String(localized: "Disconnect with Unsaved Changes?"),
                message: String(localized: "Unsaved changes in: ") + connection.editor.orderedTabs.filter { $0.document.isModified || $0.document.isDeleted }.map(\.document.name).joined(separator: ", "),
                buttons: [.init(String(localized: "Discard and Disconnect"), role: .destructive)]
            )
            if answer == 0 { forceDisconnect(forgetSession: true) }
        }
    }

    /// Ends the connection. A deliberate disconnect forgets the session;
    /// closing the window or quitting keeps it for the next launch.
    func forceDisconnect(forgetSession: Bool = false) {
        guard let connection else { return }
        if forgetSession { app.rememberSession(nil) }
        monitor?.cancel()
        monitor = nil
        connection.editor.shutdown()
        connection.externalEdits.values.forEach { $0.cancel() }
        connection.externalEdits = [:]
        hostWindow?.isDocumentEdited = false
        phase = .disconnected
        showFileDetails = false
        showTransfers = false
        Task { await connection.session.close() }
    }

    // MARK: Toolbar

    /// When space runs out, the toolbar should drop the breadcrumbs, which come
    /// back by themselves, and not the Transfers button after them, which doesn't.
    /// Returns false while the toolbar doesn't have the button yet.
    func keepTransfersInToolbar() -> Bool {
        let label = String(localized: "Transfers")
        guard let item = hostWindow?.toolbar?.items.first(where: { $0.label == label }) else { return false }
        item.visibilityPriority = .high
        return true
    }

    /// An item the toolbar has moved to its overflow menu is out of the window,
    /// so it stops laying out, keeps its old width and would never fit again.
    /// A fast resize can do that to the breadcrumbs, which learn of it late.
    private func remeasureHiddenToolbarItems() {
        guard let toolbar = hostWindow?.toolbar else { return }
        // SwiftUI can replace its toolbar items, which loses the priority.
        _ = keepTransfersInToolbar()
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        for item in toolbar.items where !visible.contains(item.itemIdentifier) {
            item.view?.invalidateIntrinsicContentSize()
            item.view?.layoutSubtreeIfNeeded()
        }
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
            title: String(localized: "Delete Server?"),
            message: String(localized: "Remove “\(server.displayName)” from your servers? Its saved password is removed too."),
            action: String(localized: "Delete")
        ) { [self] in attempt { try app.delete(server) } }
    }

    func newGroup() {
        nameRequest = NameRequest(title: String(localized: "New Server Group"), label: String(localized: "Name"), action: String(localized: "Create")) { [self] name in
            let folder = try app.addFolder(named: try Self.required(name))
            groupSelection = .folder(folder.id)
        }
    }

    func rename(_ folder: Folder) {
        nameRequest = NameRequest(title: String(localized: "Rename Group"), label: String(localized: "Name"), initial: folder.name, action: String(localized: "Rename")) { [self] name in
            try app.rename(folder, to: try Self.required(name))
        }
    }

    func confirmDelete(_ folder: Folder) {
        confirmation = Confirmation(
            title: String(localized: "Delete Group?"),
            message: String(localized: "Delete “\(folder.name)”? Servers inside will become ungrouped."),
            action: String(localized: "Delete")
        ) { [self] in
            attempt { try app.delete(folder) }
            if groupSelection == .folder(folder.id) { groupSelection = .all }
        }
    }

    func importServers() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Servers")
        panel.message = String(localized: "Choose an Edith export, a servers.json (the Linux app's is in ~/.config/edith) or a FileZilla sitemanager.xml.")
        panel.allowedContentTypes = [.json, .xml]
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file: ServerFile
        let result: ImportResult
        do {
            file = try ServerFile.read(url)
            result = try app.importServers(file)
        } catch {
            message = Message(title: String(localized: "Can't Import"), text: error.localizedDescription)
            return
        }
        var parts = ["\(result.added) added"]
        if result.updated > 0 { parts.append("\(result.updated) updated") }
        if result.foldersAdded > 0 { parts.append("\(result.foldersAdded) groups added") }
        let summary = String(localized: "Servers: ") + parts.joined(separator: ", ") + "."

        if !file.passwords.isEmpty {
            let count = file.passwords.count
            confirmation = Confirmation(
                title: String(localized: "Save \(count) Passwords to Keychain?"),
                message: summary + " The FileZilla file also has passwords for \(count) servers. Save them to your Keychain?",
                action: String(localized: "Save Passwords"), destructive: false
            ) { [self] in
                do {
                    try app.savePasswords(file.passwords)
                    announce(String(localized: "\(count) passwords saved to your Keychain"))
                } catch {
                    message = Message(title: String(localized: "Couldn't Save Passwords"), text: error.localizedDescription)
                }
            }
            return
        }
        guard let blob = file.secrets else {
            message = Message(title: String(localized: "Servers Imported"), text: summary)
            return
        }
        Task { await restorePasswords(blob, for: Set(file.servers.map(\.id)), summary: summary) }
    }

    /// Writes the server list to a file in the Linux app's format, with the
    /// passwords encrypted under a passphrase if wanted.
    func exportServers() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Servers")
        panel.nameFieldStringValue = ConfigStore.defaultExportName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let withPasswords = await choose(
                title: String(localized: "Include Passwords?"),
                message: String(localized: "Passwords are encrypted with a passphrase you choose, and needed again when importing. Without them, every server asks for its password on first connect."),
                buttons: [.init(String(localized: "Include Passwords")), .init(String(localized: "Without Passwords"))]
            )
            guard let withPasswords else { return }
            var blob: SecretsBlob?
            if withPasswords == 0 {
                guard let passphrase = await withCheckedContinuation({ continuation in
                    exportPassphraseRequest = PassphraseRequest(error: nil) { continuation.resume(returning: $0) }
                }) else { return }
                let secrets = await app.collectSecrets()
                blob = try? await Task.detached { try SecretsBlob.encrypt(secrets, passphrase: passphrase) }.value
            }
            do {
                let data = try ConfigStore.exportData(servers: app.servers, folders: app.folders, secrets: blob)
                try ConfigStore.writeExport(data, to: url, hasSecrets: blob != nil)
                let text = blob == nil
                    ? String(localized: "\(app.servers.count) servers written to \(url.lastPathComponent).")
                    : String(localized: "\(app.servers.count) servers and their passwords written to \(url.lastPathComponent).")
                message = Message(title: String(localized: "Servers Exported"), text: text)
            } catch {
                message = Message(title: String(localized: "Couldn't Export"), text: error.localizedDescription)
            }
        }
    }

    /// Asks for the export's passphrase until it's right or the user skips.
    private func restorePasswords(_ blob: SecretsBlob, for ids: Set<String>, summary: String) async {
        var error: String?
        while true {
            let passphrase: String? = await withCheckedContinuation { continuation in
                passphraseRequest = PassphraseRequest(error: error) { continuation.resume(returning: $0) }
            }
            guard let passphrase else {
                message = Message(title: String(localized: "Servers Imported"), text: summary + " Passwords weren't imported; you'll be asked for them when connecting.")
                return
            }
            do {
                let saved = try await app.restoreSecrets(blob, passphrase: passphrase, for: ids)
                message = Message(title: String(localized: "Servers Imported"), text: summary + " \(saved) passwords saved to your Keychain.")
                return
            } catch SecretsError.wrongPassphrase {
                error = String(localized: "Wrong passphrase. Try again.")
            } catch {
                message = Message(title: String(localized: "Servers Imported, Passwords Not"), text: summary + " " + error.localizedDescription)
                return
            }
        }
    }

    private static func required(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw RemoteError.failed(String(localized: "The name can't be empty.")) }
        return trimmed
    }

    // MARK: Files

    /// Opens a folder in the browser, or a file in the editor. A binary file
    /// can't be edited, so it's offered as a download instead.
    func open(_ file: RemoteFile) {
        guard let connection else { return }
        if file.isDirectory {
            Task { if await ensureConnected() { await connection.browser.open(file.path) } }
            return
        }
        Task {
            guard await ensureConnected() else { return }
            do {
                try await connection.editor.open(file.path)
                connection.reloadRecents()
            } catch WorkspaceError.binary(let name) {
                confirmation = Confirmation(
                    title: String(localized: "Can't Edit “\(name)”"),
                    message: String(localized: "It looks like a binary file, which the editor can't show. Download it instead?"),
                    action: String(localized: "Download…"), destructive: false
                ) { [self] in download([file]) }
            } catch is CancellationError {
            } catch {
                message = Message(title: String(localized: "Couldn't Open “\(file.name)”"), text: error.localizedDescription)
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
        Task { if await ensureConnected() { await connection.browser.open(path) } }
    }

    func newFile() {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: String(localized: "New File"), label: String(localized: "Name"), action: String(localized: "Create")) { name in
            try await browser.createFile(named: name)
        }
    }

    func newFolder() {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: String(localized: "New Folder"), label: String(localized: "Name"), action: String(localized: "Create")) { name in
            try await browser.createFolder(named: name)
        }
    }

    func rename(_ file: RemoteFile) {
        guard let browser = connection?.browser else { return }
        nameRequest = NameRequest(title: String(localized: "Rename"), label: String(localized: "Name"), initial: file.name, action: String(localized: "Rename")) { name in
            try await browser.rename(file, to: name)
        }
    }

    func confirmDelete(_ files: [RemoteFile]) {
        guard let browser = connection?.browser, !files.isEmpty else { return }
        let what = files.count == 1 ? String(localized: "“\(files[0].name)”") : String(localized: "\(files.count) items")
        let folders = files.contains { $0.isDirectory && !$0.isSymlink }
        confirmation = Confirmation(
            title: String(localized: "Delete \(what)?"),
            message: (folders ? String(localized: "Folders are deleted with everything in them. ") : "") + "This can't be undone.",
            action: String(localized: "Delete")
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
        folderChoice = FolderChoice(title: String(localized: "Move to"), action: String(localized: "Move"), start: browser.path) { [self] dir in
            await attempt { try await browser.move(files, to: dir) }
        }
    }

    func chooseDestination(copying files: [RemoteFile]) {
        guard let browser = connection?.browser else { return }
        folderChoice = FolderChoice(title: String(localized: "Copy to"), action: String(localized: "Copy"), start: browser.path) { [self] dir in
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
        Task { if await ensureConnected() { await browser.refresh() } }
    }

    // MARK: Transfers

    func chooseUploads() {
        guard let connection else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload")
        panel.prompt = String(localized: "Upload")
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
                message = Message(title: String(localized: "Upload Failed"), text: error.localizedDescription)
                return
            }
            if existing.isEmpty {
                await runUpload(urls, to: directory, overwrite: false, on: connection)
            } else {
                let what = existing.count == 1 ? String(localized: "“\(existing[0])” already exists") : String(localized: "\(existing.count) items already exist")
                confirmation = Confirmation(
                    title: String(localized: "Replace Existing Items?"),
                    message: String(localized: "\(what) in \(remoteName(directory)). Replacing overwrites them on the server."),
                    action: String(localized: "Replace")
                ) { [self] in await runUpload(urls, to: directory, overwrite: true, on: connection) }
            }
        }
    }

    private func runUpload(_ urls: [URL], to directory: String, overwrite: Bool, on connection: Connection) async {
        do {
            try await connection.session.upload(urls, to: directory, overwrite: overwrite)
        } catch is CancellationError {
        } catch {
            message = Message(title: String(localized: "Upload Failed"), text: error.localizedDescription)
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
            panel.title = String(localized: "Download \(files.count) Items")
            panel.prompt = String(localized: "Download")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await attempt { try await connection.session.download(files, into: url) } }
        }
    }

    // MARK: Errors

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { message = Message(title: String(localized: "Something Went Wrong"), text: error.localizedDescription) }
    }

    private func attempt(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch is CancellationError {
        } catch {
            message = Message(title: String(localized: "Something Went Wrong"), text: error.localizedDescription)
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
