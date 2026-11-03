// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibssh2
import CryptoKit
import Darwin
import Foundation
import OSLog

/// How to log in. Which secret is used follows the Linux app: a key file
/// if one is set and exists, else the password, else the SSH agent.
public struct SSHCredentials: Sendable {
    public var username: String
    public var password: String?
    public var keyFile: String?
    public var passphrase: String?
    /// The agent socket. nil uses `SSH_AUTH_SOCK`.
    public var agentSocket: String?

    public init(username: String, password: String? = nil, keyFile: String? = nil, passphrase: String? = nil, agentSocket: String? = nil) {
        self.username = username
        self.password = password
        self.keyFile = keyFile
        self.passphrase = passphrase
        self.agentSocket = agentSocket
    }
}

/// An unknown host key, for the user to accept or reject.
public struct HostKeyChallenge: Sendable {
    public var host: String
    public var port: Int
    public var keyType: String
    /// OpenSSH format: `SHA256:…`
    public var fingerprint: String
    /// Key types already on record for this host. Non-empty means the server
    /// switched key types, which deserves a stronger warning.
    public var otherKnownTypes: [String]
}

public typealias HostKeyApprover = @Sendable (HostKeyChallenge) async -> Bool

/// An SFTP connection over libssh2.
///
/// libssh2 sessions aren't thread-safe and its calls block, so each client
/// runs on its own serial queue (the actor's executor) and never on Swift's
/// shared thread pool. One client does one thing at a time: transfers use a
/// second client so they don't hold up browsing.
public actor SFTPClient: RemoteFileSystem {
    private let queue = DispatchSerialQueue(label: "de.singular.edith.sftp")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let hostKeys: HostKeyStore
    // nonisolated(unsafe) only so deinit can free them: nothing else can
    // reach the actor by then. Every other access is on the actor's queue.
    nonisolated(unsafe) private var sock: Int32 = -1
    nonisolated(unsafe) private var session: OpaquePointer?
    nonisolated(unsafe) private var sftp: OpaquePointer?
    private var keepalive: Task<Void, Never>?
    private var lost = false
    /// Read by the keyboard-interactive callback through the session's
    /// abstract pointer; it can't capture anything.
    private let kbdint = KeyboardInteractivePassword()

    public private(set) var canExec = false
    public var isConnected: Bool { sftp != nil && !lost }

    private static let log = Logger(subsystem: "de.singular.edith", category: "sftp")
    private static let libraryReady: Void = { libssh2_init(0) }()

    /// OpenSSH's host key preference. libssh2's own puts ECDSA first, which
    /// makes a host whose ed25519 key is on record look unknown.
    static let defaultHostKeyAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa",
    ]

    public init(hostKeys: HostKeyStore = HostKeyStore()) {
        self.hostKeys = hostKeys
    }

    deinit {
        keepalive?.cancel()
        if let sftp { libssh2_sftp_shutdown(sftp) }
        if let session { libssh2_session_free(session) }
        if sock >= 0 { Darwin.close(sock) }
    }

    // MARK: Connecting

    /// Connects, verifies the host key and logs in. `approveHostKey` is asked
    /// about keys that aren't on record; accepted keys are saved. A changed
    /// or revoked key fails without asking.
    public func connect(
        host: String,
        port: Int = 22,
        credentials: SSHCredentials,
        timeout: Duration = .seconds(10),
        approveHostKey: HostKeyApprover
    ) async throws {
        _ = Self.libraryReady
        guard session == nil else { throw RemoteError.failed("Already connected.") }
        do {
            try await establish(host: host, port: port, credentials: credentials, timeout: timeout, approveHostKey: approveHostKey)
        } catch {
            teardown()
            throw error
        }
        startKeepalive()
        // Shared hosts often allow SFTP but not shell commands.
        canExec = (try? await exec("echo ok", timeout: .seconds(5)))?.status == 0
    }

    private func establish(host: String, port: Int, credentials: SSHCredentials, timeout: Duration, approveHostKey: HostKeyApprover) async throws {
        sock = try openSocket(host: host, port: port, timeout: timeout)
        session = libssh2_session_init_ex(nil, nil, nil, Unmanaged.passUnretained(kbdint).toOpaque())
        guard let session else { throw RemoteError.connectionFailed("Couldn't create an SSH session.") }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Int(timeout.components.seconds) * 1000)

        // Ask for a key type we can check: those on record first.
        let known = hostKeys.knownKeyTypes(host: host, port: port).flatMap { type in
            type == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"] : [type]
        }
        var algorithms: [String] = []
        for a in known + Self.defaultHostKeyAlgorithms where !algorithms.contains(a) { algorithms.append(a) }
        libssh2_session_method_pref(session, LIBSSH2_METHOD_HOSTKEY, algorithms.joined(separator: ","))

        guard libssh2_session_handshake(session, sock) == 0 else {
            throw RemoteError.connectionFailed(lastErrorMessage())
        }
        try await verifyHostKey(host: host, port: port, approve: approveHostKey)
        try authenticate(credentials)

        sftp = libssh2_sftp_init(session)
        guard sftp != nil else { throw RemoteError.connectionFailed("The server refused the SFTP subsystem: \(lastErrorMessage())") }
        libssh2_session_set_timeout(session, 60_000)
    }

    private func verifyHostKey(host: String, port: Int, approve: HostKeyApprover) async throws {
        var length = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(session, &length, &type) else {
            throw RemoteError.connectionFailed("The server sent no host key.")
        }
        let key = Data(bytes: raw, count: length)
        let keyType = sshStringPrefix(key) ?? "unknown"
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")

        switch hostKeys.status(host: host, port: port, keyType: keyType, key: key) {
        case .match:
            return
        case .mismatch:
            throw RemoteError.hostKeyChanged(host: host, keyType: keyType, fingerprint: fingerprint)
        case .revoked:
            throw RemoteError.hostKeyRevoked(host: host)
        case .notFound(let others):
            let challenge = HostKeyChallenge(host: host, port: port, keyType: keyType, fingerprint: fingerprint, otherKnownTypes: others)
            guard await approve(challenge) else { throw RemoteError.hostKeyRejected }
            try hostKeys.add(host: host, port: port, keyType: keyType, key: key)
        }
    }

    private func authenticate(_ c: SSHCredentials) throws {
        let user = c.username
        let userLen = UInt32(user.utf8.count)
        // Asking for the list also tries "none" auth, which a few servers accept.
        let offered = libssh2_userauth_list(session, user, userLen).map { String(cString: $0) } ?? ""
        if libssh2_userauth_authenticated(session) != 0 { return }
        let methods = Set(offered.split(separator: ",").map(String.init))

        if let keyFile = resolveKeyFile(c.keyFile) {
            guard libssh2_userauth_publickey_fromfile_ex(session, user, userLen, nil, keyFile, c.passphrase) == 0 else {
                throw RemoteError.authenticationFailed(lastErrorMessage())
            }
        } else if let password = c.password {
            if methods.contains("password"),
               libssh2_userauth_password_ex(session, user, userLen, password, UInt32(password.utf8.count), nil) == 0 {
                return
            }
            // Many servers only offer keyboard-interactive, which asks for
            // the same password through a prompt.
            if methods.contains("keyboard-interactive") {
                kbdint.password = password
                defer { kbdint.password = nil }
                if libssh2_userauth_keyboard_interactive_ex(session, user, userLen, keyboardInteractiveResponse) == 0 { return }
            }
            throw RemoteError.authenticationFailed(methods.isDisjoint(with: ["password", "keyboard-interactive"])
                ? "The server doesn't accept passwords (it offers: \(offered))."
                : "Wrong user name or password.")
        } else {
            try authenticateWithAgent(user, socket: c.agentSocket)
        }
    }

    private func authenticateWithAgent(_ user: String, socket: String?) throws {
        guard let agent = libssh2_agent_init(session) else { throw RemoteError.authenticationFailed(lastErrorMessage()) }
        defer { libssh2_agent_disconnect(agent); libssh2_agent_free(agent) }
        if let socket { libssh2_agent_set_identity_path(agent, socket) }
        guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0 else {
            throw RemoteError.authenticationFailed("No password or key is set, and the SSH agent isn't available.")
        }
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var tried = 0
        while libssh2_agent_get_identity(agent, &identity, previous) == 0 {
            tried += 1
            if libssh2_agent_userauth(agent, user, identity) == 0 { return }
            previous = identity
        }
        throw RemoteError.authenticationFailed(tried == 0 ? "The SSH agent has no keys." : "The server rejected all \(tried) SSH agent keys.")
    }

    /// The key file to use, or nil to fall back to password or agent as the
    /// Linux app does. Imported Linux configs point at /home/<user>/.ssh/…,
    /// so a missing file is also looked for under this user's ~/.ssh.
    private func resolveKeyFile(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return expanded }
        let local = URL.homeDirectory.appending(path: ".ssh/\((expanded as NSString).lastPathComponent)").path
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    public func close() async {
        teardown()
    }

    private func teardown() {
        keepalive?.cancel()
        keepalive = nil
        if let sftp { libssh2_sftp_shutdown(sftp) }
        sftp = nil
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Closed by Edith", "")
            libssh2_session_free(session)
        }
        session = nil
        if sock >= 0 { Darwin.close(sock) }
        sock = -1
        canExec = false
    }

    private func startKeepalive() {
        libssh2_keepalive_config(session, 1, 30)
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.sendKeepalive()
            }
        }
    }

    private func sendKeepalive() {
        guard let session, !lost else { return }
        var next: Int32 = 0
        if libssh2_keepalive_send(session, &next) != 0 {
            lost = true
            Self.log.notice("keepalive failed, connection lost: \(self.lastErrorMessage(), privacy: .public)")
        }
    }

    // MARK: Errors

    private func lastErrorMessage() -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        return message.map { String(cString: $0) } ?? "Unknown error"
    }

    /// The error for a failed call, using the SFTP status when there is one.
    private func failure(_ path: String) -> RemoteError {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        let code = libssh2_session_last_error(session, &message, &length, 0)
        let text = message.map { String(cString: $0) } ?? "Unknown error"

        switch code {
        case LIBSSH2_ERROR_SFTP_PROTOCOL:
            let status = libssh2_sftp_last_error(sftp)
            switch status {
            case LIBSSH2_FX_NO_SUCH_FILE, LIBSSH2_FX_NO_SUCH_PATH: return .noSuchFile(path)
            case LIBSSH2_FX_PERMISSION_DENIED, LIBSSH2_FX_WRITE_PROTECT: return .permissionDenied(path)
            case LIBSSH2_FX_FILE_ALREADY_EXISTS: return .alreadyExists(path)
            case LIBSSH2_FX_DIR_NOT_EMPTY: return .failed("“\(remoteName(path))” isn't empty.")
            case LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM, LIBSSH2_FX_QUOTA_EXCEEDED: return .failed("The server is out of space.")
            default: return .failed("\(remoteName(path)): the server reported an error (SFTP status \(status)).")
            }
        case LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV, LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_TIMEOUT:
            lost = true
            return .connectionFailed(text)
        default:
            return .failed(text)
        }
    }

    private func requireSFTP() throws -> OpaquePointer {
        guard let sftp, !lost else { throw RemoteError.notConnected }
        return sftp
    }

    // MARK: Reading

    public func normalize(_ path: String) async throws -> String {
        let sftp = try requireSFTP()
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH)
        guard n > 0 else { throw failure(path) }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        let sftp = try requireSFTP()
        guard let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR) else {
            throw failure(path)
        }
        defer { libssh2_sftp_close_handle(handle) }

        var files: [RemoteFile] = []
        var name = [CChar](repeating: 0, count: 4096)
        var longEntry = [CChar](repeating: 0, count: 4096)
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            try Task.checkCancellation()
            let n = libssh2_sftp_readdir_ex(handle, &name, name.count, &longEntry, longEntry.count, &attrs)
            if n == 0 { break }
            guard n > 0 else { throw failure(path) }
            let filename = String(decoding: name.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if filename == "." || filename == ".." { continue }

            var file = remoteFile(name: filename, path: remoteJoin(path, filename), attrs: attrs)
            // `ls -l` style long name: fields 3 and 4 are owner and group.
            let fields = cString(longEntry).split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 4 {
                file.owner = String(fields[2])
                file.group = String(fields[3])
            }
            if file.isSymlink {
                // readdir describes the link itself; show folders as folders.
                var target = LIBSSH2_SFTP_ATTRIBUTES()
                if libssh2_sftp_stat_ex(sftp, file.path, UInt32(file.path.utf8.count), LIBSSH2_SFTP_STAT, &target) == 0 {
                    file.isDirectory = isDirectoryMode(target)
                }
            }
            files.append(file)
        }
        return files
    }

    public func stat(_ path: String) async throws -> RemoteFile {
        let sftp = try requireSFTP()
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        guard libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_STAT, &attrs) == 0 else {
            throw failure(path)
        }
        return remoteFile(name: remoteName(path), path: path, attrs: attrs)
    }

    private func remoteFile(name: String, path: String, attrs: LIBSSH2_SFTP_ATTRIBUTES) -> RemoteFile {
        let has = { (flag: Int32) in attrs.flags & UInt(flag) != 0 }
        let mode = has(LIBSSH2_SFTP_ATTR_PERMISSIONS) ? UInt32(attrs.permissions) : 0
        return RemoteFile(
            name: name,
            path: path,
            size: has(LIBSSH2_SFTP_ATTR_SIZE) ? attrs.filesize : 0,
            isDirectory: isDirectoryMode(attrs),
            isSymlink: mode & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFLNK),
            mode: mode,
            modified: has(LIBSSH2_SFTP_ATTR_ACMODTIME) ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime)) : nil,
            owner: has(LIBSSH2_SFTP_ATTR_UIDGID) ? String(attrs.uid) : "",
            group: has(LIBSSH2_SFTP_ATTR_UIDGID) ? String(attrs.gid) : ""
        )
    }

    private func isDirectoryMode(_ attrs: LIBSSH2_SFTP_ATTRIBUTES) -> Bool {
        attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            && attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFDIR)
    }

    // MARK: Transfers

    /// 1 MiB reads let libssh2 keep many requests in flight; ~290 MB/s on
    /// loopback in the Phase 0 spike.
    private static let chunkSize = 1 << 20

    public func download(_ remotePath: String, to localURL: URL, progress: TransferProgress?) async throws {
        let sftp = try requireSFTP()
        guard let handle = libssh2_sftp_open_ex(sftp, remotePath, UInt32(remotePath.utf8.count),
                                                UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        else { throw failure(remotePath) }
        defer { libssh2_sftp_close_handle(handle) }

        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let total = libssh2_sftp_fstat_ex(handle, &attrs, 0) == 0 ? attrs.filesize : 0

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw RemoteError.failed("Can't write \(localURL.path).")
        }
        let out = try FileHandle(forWritingTo: localURL)
        var completed = false
        defer {
            try? out.close()
            // A partial file must not be mistaken for the real one.
            if !completed { try? FileManager.default.removeItem(at: localURL) }
        }

        var buffer = [CChar](repeating: 0, count: Self.chunkSize)
        var done: UInt64 = 0
        progress?(0, total)
        while true {
            try Task.checkCancellation()
            let n = libssh2_sftp_read(handle, &buffer, buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw failure(remotePath) }
            try buffer.withUnsafeBytes { try out.write(contentsOf: $0.prefix(n)) }
            done += UInt64(n)
            progress?(done, total)
        }
        completed = true
    }

    public func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: TransferProgress?) async throws {
        let sftp = try requireSFTP()
        if !overwrite, try await exists(remotePath) { throw RemoteError.alreadyExists(remotePath) }

        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        let total = UInt64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        // Written in place, not to a temp file and renamed: renaming would
        // replace the file's owner and permissions on the server.
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        guard let handle = libssh2_sftp_open_ex(sftp, remotePath, UInt32(remotePath.utf8.count), flags, 0o644, LIBSSH2_SFTP_OPENFILE)
        else { throw failure(remotePath) }
        defer { libssh2_sftp_close_handle(handle) }

        var done: UInt64 = 0
        progress?(0, total)
        while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try write(chunk, to: handle, path: remotePath)
            done += UInt64(chunk.count)
            progress?(done, total)
        }
    }

    /// libssh2_sftp_write may take less than it's given; loop until it's all sent.
    private func write(_ data: Data, to handle: OpaquePointer, path: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let n = libssh2_sftp_write(handle, bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), bytes.count - offset)
                guard n > 0 else { throw failure(path) }
                offset += n
            }
        }
    }

    // MARK: Changing things

    public func mkdir(_ path: String) async throws {
        let sftp = try requireSFTP()
        guard libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), 0o755) == 0 else {
            let error = failure(path)
            // OpenSSH answers a duplicate with a generic failure.
            if try await exists(path) { throw RemoteError.alreadyExists(path) }
            throw error
        }
    }

    public func rename(_ from: String, to: String) async throws {
        let sftp = try requireSFTP()
        if try await exists(to) { throw RemoteError.alreadyExists(to) }
        let flags = Int(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
        guard libssh2_sftp_rename_ex(sftp, from, UInt32(from.utf8.count), to, UInt32(to.utf8.count), flags) == 0 else {
            throw failure(from)
        }
    }

    public func chmod(_ path: String, permissions: UInt32) async throws {
        let sftp = try requireSFTP()
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        attrs.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attrs.permissions = UInt(permissions & 0o7777)
        guard libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attrs) == 0 else {
            throw failure(path)
        }
    }

    public func remove(_ path: String) async throws {
        let sftp = try requireSFTP()
        guard libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count)) == 0 else { throw failure(path) }
    }

    public func rmdir(_ path: String) async throws {
        let sftp = try requireSFTP()
        guard libssh2_sftp_rmdir_ex(sftp, path, UInt32(path.utf8.count)) == 0 else { throw failure(path) }
    }

    public func createFile(_ path: String) async throws {
        let sftp = try requireSFTP()
        if try await exists(path) { throw RemoteError.alreadyExists(path) }
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL)
        guard let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), flags, 0o644, LIBSSH2_SFTP_OPENFILE) else {
            throw failure(path)
        }
        libssh2_sftp_close_handle(handle)
    }

    public func copyFile(_ from: String, to: String) async throws {
        let sftp = try requireSFTP()
        if try await exists(to) { throw RemoteError.alreadyExists(to) }
        let source = try await stat(from)

        guard let input = libssh2_sftp_open_ex(sftp, from, UInt32(from.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) else {
            throw failure(from)
        }
        defer { libssh2_sftp_close_handle(input) }
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let mode = Int(source.permissions == 0 ? 0o644 : source.permissions)
        guard let output = libssh2_sftp_open_ex(sftp, to, UInt32(to.utf8.count), flags, mode, LIBSSH2_SFTP_OPENFILE) else {
            throw failure(to)
        }
        defer { libssh2_sftp_close_handle(output) }

        var buffer = [CChar](repeating: 0, count: Self.chunkSize)
        while true {
            try Task.checkCancellation()
            let n = libssh2_sftp_read(input, &buffer, buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw failure(from) }
            try write(Data(bytes: buffer, count: n), to: output, path: to)
        }
    }

    // MARK: Exec

    public func exec(_ command: String) async throws -> ExecResult {
        try await exec(command, timeout: .seconds(600))
    }

    /// Runs a command over an SSH exec channel. stdout and stderr are read
    /// together in non-blocking mode, so a command that floods one of them
    /// can't stall the other and deadlock the channel.
    public func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        guard let session, !lost else { throw RemoteError.notConnected }
        guard let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw RemoteError.failed("Couldn't open an exec channel: \(lastErrorMessage())")
        }
        defer { libssh2_channel_free(channel) }
        guard libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)) == 0 else {
            throw RemoteError.failed("The server refused to run the command: \(lastErrorMessage())")
        }

        libssh2_session_set_blocking(session, 0)
        defer { libssh2_session_set_blocking(session, 1) }

        let deadline = ContinuousClock.now + timeout
        var stdout = Data(), stderr = Data()
        var buffer = [CChar](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            var progressed = false
            for stream in [Int32(0), SSH_EXTENDED_DATA_STDERR] {
                let n = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                if n > 0 {
                    let chunk = Data(bytes: buffer, count: n)
                    if stream == 0 { stdout.append(chunk) } else { stderr.append(chunk) }
                    progressed = true
                } else if n < 0 && Int32(n) != LIBSSH2_ERROR_EAGAIN {
                    throw failure(command)
                }
            }
            if libssh2_channel_eof(channel) != 0 && !progressed { break }
            if ContinuousClock.now > deadline { throw RemoteError.failed("The command timed out.") }
            if !progressed { waitForSocket(session, milliseconds: 100) }
        }

        while libssh2_channel_close(channel) == LIBSSH2_ERROR_EAGAIN { waitForSocket(session, milliseconds: 100) }
        while libssh2_channel_wait_closed(channel) == LIBSSH2_ERROR_EAGAIN { waitForSocket(session, milliseconds: 100) }
        return ExecResult(
            status: Int(libssh2_channel_get_exit_status(channel)),
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private func waitForSocket(_ session: OpaquePointer, milliseconds: Int32) {
        let directions = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
        var fd = pollfd(fd: sock, events: events == 0 ? Int16(POLLIN) : events, revents: 0)
        _ = poll(&fd, 1, milliseconds)
    }
}

// MARK: - Helpers

/// Holds the password the keyboard-interactive callback hands to the server.
private final class KeyboardInteractivePassword: @unchecked Sendable {
    var password: String?
}

/// Answers every keyboard-interactive prompt with the password. libssh2
/// frees each response with free(), so they're allocated with strdup().
private let keyboardInteractiveResponse: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, count, _, responses, abstract in
    guard let responses, let raw = abstract?.pointee else { return }
    let box = Unmanaged<KeyboardInteractivePassword>.fromOpaque(raw).takeUnretainedValue()
    guard let password = box.password else { return }
    for i in 0..<Int(count) {
        responses[i].text = strdup(password)
        responses[i].length = UInt32(password.utf8.count)
    }
}

/// A NUL-terminated buffer as a String.
private func cString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// The key type at the start of an SSH public key blob (a length-prefixed string).
func sshStringPrefix(_ blob: Data) -> String? {
    guard blob.count >= 4 else { return nil }
    let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    guard length > 0, blob.count >= 4 + length else { return nil }
    return String(bytes: blob.dropFirst(4).prefix(length), encoding: .utf8)
}

/// A connected TCP socket, with a connect timeout and SIGPIPE disabled (a
/// write to a dropped connection would otherwise kill the app).
func openSocket(host: String, port: Int, timeout: Duration) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &result)
    guard rc == 0, let first = result else {
        throw RemoteError.connectionFailed("Can't resolve \(host): \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(result) }

    let millis = Int32(timeout.components.seconds * 1000)
    var lastError = ECONNREFUSED
    var info: UnsafeMutablePointer<addrinfo>? = first
    while let ai = info {
        info = ai.pointee.ai_next
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { lastError = errno; continue }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var connected = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
        if !connected && errno == EINPROGRESS {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&p, 1, millis) == 1 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                connected = err == 0
                lastError = err
            } else {
                lastError = ETIMEDOUT
            }
        } else if !connected {
            lastError = errno
        }
        if connected {
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
        Darwin.close(fd)
    }
    throw RemoteError.connectionFailed("Can't connect to \(host):\(port): \(String(cString: strerror(lastError)))")
}
