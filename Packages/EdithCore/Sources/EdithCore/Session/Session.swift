// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import OSLog

/// One connection to a server, as a window holds it: the client used for
/// browsing, a transfer queue, and a second client for transfers so a long
/// upload doesn't hold up browsing.
@MainActor
@Observable
public final class Session {
    public let server: Server
    public let client: any RemoteFileSystem
    public let transfers = TransferQueue()
    /// The login directory, from `normalize(".")`.
    public let home: String
    /// Where browsing starts: the server's initial directory, resolved.
    public let startDirectory: String
    public private(set) var canExec: Bool

    @ObservationIgnored private let makeClient: @Sendable () async throws -> any RemoteFileSystem
    @ObservationIgnored private var transferClient: Task<any RemoteFileSystem, Never>?
    private static let log = Logger(subsystem: "de.singular.edith", category: "session")

    private init(server: Server, client: any RemoteFileSystem, home: String, startDirectory: String, canExec: Bool,
                 makeClient: @escaping @Sendable () async throws -> any RemoteFileSystem) {
        self.server = server
        self.client = client
        self.home = home
        self.startDirectory = startDirectory
        self.canExec = canExec
        self.makeClient = makeClient
    }

    /// Connects to `server`. `secret` is the password or key passphrase,
    /// whichever the server's auth method needs (see `Server.secretKind`).
    public static func connect(
        to server: Server,
        secret: String?,
        hostKeys: HostKeyStore,
        approveHostKey: @escaping HostKeyApprover
    ) async throws -> Session {
        guard server.serverProtocol == .sftp else {
            throw RemoteError.unsupported("FTP isn't supported yet. It's coming in a later version.")
        }
        let credentials = server.credentials(secret: secret)
        let makeClient: @Sendable () async throws -> any RemoteFileSystem = {
            let client = SFTPClient(hostKeys: hostKeys)
            // The first connection already settled the host key; a second
            // prompt would mean it changed in between, so refuse instead.
            try await client.connect(host: server.host, port: server.port, credentials: credentials, approveHostKey: { _ in false })
            return client
        }

        let client = SFTPClient(hostKeys: hostKeys)
        try await client.connect(host: server.host, port: server.port, credentials: credentials, approveHostKey: approveHostKey)
        let home = (try? await client.normalize(".")) ?? "/"
        let start = await resolveStart(server.initialDirectory, home: home, client: client)
        return Session(server: server, client: client, home: home, startDirectory: start,
                       canExec: await client.canExec, makeClient: makeClient)
    }

    /// `~` and `~/…` expand to the home directory; a start directory that
    /// doesn't exist (any more) falls back to home rather than failing.
    private static func resolveStart(_ initial: String, home: String, client: SFTPClient) async -> String {
        var path = initial.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { path = "/" }
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = remoteJoin(home, String(path.dropFirst(2))) }
        if let found = try? await client.stat(path), found.isDirectory { return path }
        return home
    }

    /// The connection transfers run on. Opened on first use; if the server
    /// won't allow a second connection, transfers share the browsing one.
    public func transferConnection() async -> any RemoteFileSystem {
        if let transferClient { return await transferClient.value }
        let fallback = client
        let task = Task { [makeClient] () -> any RemoteFileSystem in
            do {
                return try await makeClient()
            } catch {
                Self.log.notice("second connection refused, sharing the browsing one: \(error.localizedDescription, privacy: .public)")
                return fallback
            }
        }
        transferClient = task
        return await task.value
    }

    public func close() async {
        await transfers.clear()
        await client.close()
        if let transferClient {
            let other = await transferClient.value
            if other !== client { await other.close() }
        }
        transferClient = nil
    }

    // MARK: Transfers

    /// Names in `directory` that uploading `urls` would replace.
    public func conflicts(uploading urls: [URL], to directory: String) async throws -> [String] {
        var names: [String] = []
        for url in urls where try await client.exists(remoteJoin(directory, url.lastPathComponent)) {
            names.append(url.lastPathComponent)
        }
        return names
    }

    /// Uploads files and folders into `directory`, one queue job each, and
    /// returns when all are done. Throws the first failure.
    public func upload(_ urls: [URL], to directory: String, overwrite: Bool) async throws {
        try await runAll(urls.map { url in
            (url.lastPathComponent, { [self] progress in
                let fs = await transferConnection()
                let target = remoteJoin(directory, url.lastPathComponent)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try await fs.uploadDirectory(url, to: target, overwrite: overwrite, progress: progress.callback)
                } else {
                    try await fs.upload(url, to: target, overwrite: overwrite, progress: progress.callback)
                }
            })
        })
    }

    /// Downloads files and folders into a local directory.
    public func download(_ files: [RemoteFile], into localDirectory: URL) async throws {
        try await runAll(files.map { file in
            (file.name, { [self] progress in
                let fs = await transferConnection()
                try await fs.downloadTree(file.path, to: localDirectory.appending(path: file.name), progress: progress.callback)
            })
        })
    }

    /// Downloads one file or folder to an exact local URL.
    public func download(_ file: RemoteFile, to localURL: URL) async throws {
        let job: TransferQueue.Work = { [self] progress in
            let fs = await transferConnection()
            try await fs.downloadTree(file.path, to: localURL, progress: progress.callback)
        }
        try await runAll([(file.name, job)])
    }

    private func runAll(_ jobs: [(String, TransferQueue.Work)]) async throws {
        let queue = transfers
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (label, work) in jobs {
                group.addTask { try await queue.perform(label, work: work) }
            }
            try await group.waitForAll()
        }
    }
}

extension Server {
    public enum SecretKind: Sendable {
        case none, password, passphrase
    }

    /// Which secret connecting needs: FTP and password auth need a password;
    /// key auth with a passphrase needs the passphrase; plain key auth needs
    /// nothing, and without a key file it uses the SSH agent.
    public var secretKind: SecretKind {
        if serverProtocol == .ftp { return .password }
        switch authMethod {
        case .password: return .password
        case .key: return .none
        case .keyWithPassphrase: return .passphrase
        }
    }

    func credentials(secret: String?) -> SSHCredentials {
        switch secretKind {
        case .none: SSHCredentials(username: username, keyFile: keyFile)
        case .password: SSHCredentials(username: username, password: secret)
        case .passphrase: SSHCredentials(username: username, keyFile: keyFile, passphrase: secret)
        }
    }
}
