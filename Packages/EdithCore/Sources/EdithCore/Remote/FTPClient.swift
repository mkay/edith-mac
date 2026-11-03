// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibssh2
import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

/// A server certificate macOS doesn't trust, for the user to accept or not.
public struct CertificateChallenge: Sendable {
    public var host: String
    public var port: Int
    public var subject: String
    public var issuer: String
    /// Why the system rejected it, in the system's words.
    public var reason: String
    /// SHA-256 of the certificate, as colon-separated hex.
    public var fingerprint: String
}

public typealias CertificateApprover = @Sendable (CertificateChallenge) async -> Bool

/// Certificates the user accepted although macOS didn't trust them, by
/// host and port, so the question comes once per certificate.
public final class CertificateStore: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Edith/trusted_certificates.json")
    }

    public init(fileURL: URL = CertificateStore.defaultURL) {
        self.fileURL = fileURL
    }

    private func load() -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public func isTrusted(_ fingerprint: String, host: String, port: Int) -> Bool {
        load()["\(host):\(port)"]?.contains(fingerprint) == true
    }

    public func trust(_ fingerprint: String, host: String, port: Int) throws {
        var all = load()
        all["\(host):\(port)", default: []].append(fingerprint)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}

/// An FTP or FTPS connection.
///
/// Like SFTPClient, it runs blocking socket calls on its own serial queue.
/// TLS is OpenSSL rather than Network.framework because FTPS needs the data
/// connection to resume the control connection's TLS session, which vsftpd
/// and others require and which only a TLS library exposing sessions allows.
public actor FTPClient: RemoteFileSystem {
    public enum Security: Sendable {
        case none
        /// AUTH TLS, falling back to plain FTP if the server refuses it.
        case explicitOptional
        case explicitRequired
        /// TLS from the first byte, usually on port 990.
        case implicit
    }

    private let queue = DispatchSerialQueue(label: "de.singular.edith.ftp")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let certificates: CertificateStore
    private var control: FTPStream?
    private var tls: TLSContext?
    private var host = ""
    private var port = 21
    private var hasMLST = false
    private var lost = false
    private var lastActivity = ContinuousClock.now
    private var keepalive: Task<Void, Never>?
    /// Whether the last data connection resumed the TLS session (tests).
    private(set) var lastDataSessionReused = false

    public var canExec: Bool { false }
    public var isConnected: Bool { control != nil && !lost }
    private static let log = Logger(subsystem: "de.singular.edith", category: "ftp")

    public init(certificates: CertificateStore = CertificateStore()) {
        self.certificates = certificates
    }

    deinit {
        keepalive?.cancel()
    }

    // MARK: Connecting

    public func connect(
        host: String, port: Int = 21, username: String, password: String?,
        security: Security, timeout: Duration = .seconds(15),
        approveCertificate: CertificateApprover
    ) async throws {
        self.host = host
        self.port = port
        let fd = try openSocket(host: host, port: port, timeout: timeout)
        let stream = FTPStream(fd: fd)
        stream.setTimeout(timeout)
        control = stream
        do {
            if security == .implicit {
                try await startTLS(on: stream, approve: approveCertificate)
            }
            let greeting = try reply()
            guard greeting.code == 220 else { throw RemoteError.connectionFailed(greeting.text) }

            if security == .explicitRequired || security == .explicitOptional {
                let auth = try command("AUTH TLS")
                if auth.code == 234 {
                    try await startTLS(on: stream, approve: approveCertificate)
                } else if security == .explicitRequired {
                    throw RemoteError.connectionFailed(String(localized: "The server doesn't support FTPS (AUTH TLS): \(auth.text)", bundle: .module))
                }
            }

            var login = try command("USER \(username.isEmpty ? "anonymous" : username)")
            if login.code == 331 { login = try command("PASS \(password ?? "")") }
            guard login.code == 230 else { throw RemoteError.authenticationFailed(login.text) }

            if tls != nil {
                _ = try command("PBSZ 0")
                let prot = try command("PROT P")
                guard prot.isSuccess else { throw RemoteError.connectionFailed(String(localized: "The server refused encrypted transfers: \(prot.text)", bundle: .module)) }
            }
            let features = try command("FEAT")
            let feats = features.text.uppercased()
            hasMLST = feats.contains("MLST")
            if feats.contains("UTF8") { _ = try command("OPTS UTF8 ON") }
            _ = try command("TYPE I")
        } catch {
            teardown()
            throw error
        }
        startKeepalive()
    }

    private func startTLS(on stream: FTPStream, approve: CertificateApprover) async throws {
        let context = try tls ?? TLSContext()
        tls = context
        try stream.startTLS(context, host: host, resuming: nil)
        try await verify(stream.peerCertificates(), approve: approve)
    }

    /// Accepts a chain macOS trusts for this host, or one the user accepted
    /// before; otherwise asks.
    private func verify(_ chain: [SecCertificate], approve: CertificateApprover) async throws {
        guard let leaf = chain.first else { throw RemoteError.connectionFailed(String(localized: "The server sent no certificate.", bundle: .module)) }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        var error: CFError?
        if let trust, SecTrustEvaluateWithError(trust, &error) { return }

        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
        if certificates.isTrusted(fingerprint, host: host, port: port) { return }
        let challenge = CertificateChallenge(
            host: host, port: port,
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "?",
            issuer: chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? ?? "?" : "(self-signed)",
            reason: (error.map { CFErrorCopyDescription($0) as String }) ?? "Not trusted",
            fingerprint: fingerprint
        )
        guard await approve(challenge) else { throw RemoteError.hostKeyRejected }
        try certificates.trust(fingerprint, host: host, port: port)
    }

    public func close() async {
        if control != nil, !lost { _ = try? command("QUIT") }
        teardown()
    }

    private func teardown() {
        keepalive?.cancel()
        keepalive = nil
        control?.close()
        control = nil
    }

    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.noopIfIdle()
            }
        }
    }

    /// Servers drop idle control connections; a NOOP now and then keeps it.
    private func noopIfIdle() {
        guard control != nil, !lost, ContinuousClock.now - lastActivity > .seconds(25) else { return }
        if (try? command("NOOP"))?.isSuccess != true { lost = true }
    }

    // MARK: Control channel

    struct Reply {
        var code: Int
        var text: String
        var isSuccess: Bool { (200..<300).contains(code) }
        var isPreliminary: Bool { (100..<200).contains(code) }
    }

    private func requireControl() throws -> FTPStream {
        guard let control, !lost else { throw RemoteError.notConnected }
        return control
    }

    @discardableResult
    private func command(_ line: String) throws -> Reply {
        let control = try requireControl()
        do {
            try control.writeLine(line)
            return try reply()
        } catch let error as RemoteError {
            throw error
        } catch {
            lost = true
            throw RemoteError.connectionFailed(error.localizedDescription)
        }
    }

    /// Reads one reply, joining a multi-line one (`123-…` through `123 …`).
    private func reply() throws -> Reply {
        let control = try requireControl()
        lastActivity = .now
        do {
            let first = try control.readLine()
            guard first.count >= 3, let code = Int(first.prefix(3)) else {
                throw RemoteError.failed(String(localized: "Unexpected reply from the server: \(first)", bundle: .module))
            }
            var lines = [first]
            if first.dropFirst(3).first == "-" {
                let end = "\(first.prefix(3)) "
                while true {
                    let next = try control.readLine()
                    lines.append(next)
                    if next.hasPrefix(end) { break }
                }
            }
            if code == 421 { lost = true }
            return Reply(code: code, text: lines.joined(separator: "\n"))
        } catch let error as RemoteError {
            throw error
        } catch {
            lost = true
            throw RemoteError.connectionFailed(error.localizedDescription)
        }
    }

    /// Maps a failure reply to the error the browser understands.
    private func failure(_ reply: Reply, path: String) -> RemoteError {
        let text = reply.text.lowercased()
        if reply.code == 421 { return .connectionFailed(reply.text) }
        if text.contains("permission") || text.contains("denied") || text.contains("not allowed") { return .permissionDenied(path) }
        if text.contains("exist") && !text.contains("not exist") && !text.contains("doesn't exist") { return .alreadyExists(path) }
        if reply.code == 550 { return .noSuchFile(path) }
        return .failed(reply.text)
    }

    // MARK: Data channel

    /// Opens a data connection, sends `line` and returns the stream once the
    /// server agreed (1xx). The caller reads or writes it, then `finish`es.
    private func openData(_ line: String, path: String) throws -> FTPStream {
        let address = try passiveAddress()
        let fd = try openSocket(host: address.host, port: address.port, timeout: .seconds(15))
        let data = FTPStream(fd: fd)
        data.setTimeout(.seconds(60))
        let answer = try command(line)
        guard answer.isPreliminary else {
            data.close()
            throw failure(answer, path: path)
        }
        if let tls, let control {
            do {
                try data.startTLS(tls, host: host, resuming: control.session)
                lastDataSessionReused = data.sessionReused
            } catch {
                data.close()
                _ = try? reply()
                throw RemoteError.failed(String(localized: "The encrypted data connection failed: \(error.localizedDescription)", bundle: .module))
            }
        }
        return data
    }

    private func finish(_ data: FTPStream, path: String) throws {
        data.close()
        let done = try reply()
        guard done.isSuccess else { throw failure(done, path: path) }
    }

    /// Stops a transfer midway: ABOR, then the one or two replies it causes.
    private func abort(_ data: FTPStream) {
        data.close()
        _ = try? command("ABOR")
        if let control { control.setTimeout(.seconds(2)) }
        _ = try? reply()
        if let control { control.setTimeout(.seconds(15)) }
    }

    /// EPSV, or PASV for servers without it. Either way the connection goes
    /// to the control connection's host: PASV addresses are often internal
    /// ones that only work inside the server's network.
    private func passiveAddress() throws -> (host: String, port: Int) {
        let epsv = try command("EPSV")
        if epsv.code == 229, let match = epsv.text.firstMatch(of: /\(\|\|\|(\d+)\|\)/), let port = Int(match.1) {
            return (host, port)
        }
        let pasv = try command("PASV")
        guard pasv.code == 227, let m = pasv.text.firstMatch(of: /(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/),
              let hi = Int(m.5), let lo = Int(m.6)
        else { throw RemoteError.failed(String(localized: "The server refused passive mode: \(pasv.text)", bundle: .module)) }
        return (host, hi * 256 + lo)
    }

    private func readAll(_ data: FTPStream) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = try data.read(&buffer)
            if n == 0 { break }
            result.append(contentsOf: buffer[..<n])
        }
        return result
    }

    // MARK: Reading

    public func normalize(_ path: String) async throws -> String {
        if path == "." { return try pwd() }
        let old = try pwd()
        let cwd = try command("CWD \(path)")
        guard cwd.isSuccess else { throw failure(cwd, path: path) }
        defer { _ = try? command("CWD \(old)") }
        return try pwd()
    }

    private func pwd() throws -> String {
        let r = try command("PWD")
        guard r.code == 257, let start = r.text.firstIndex(of: "\"") else { throw RemoteError.failed(r.text) }
        // The path is quoted; a quote inside it is doubled.
        var path = ""
        var i = r.text.index(after: start)
        while i < r.text.endIndex {
            let c = r.text[i]
            let next = r.text.index(after: i)
            if c == "\"" {
                if next < r.text.endIndex, r.text[next] == "\"" { path.append("\""); i = r.text.index(after: next); continue }
                break
            }
            path.append(c)
            i = next
        }
        return path
    }

    private func isDirectory(_ path: String) throws -> Bool {
        let old = try pwd()
        guard try command("CWD \(path)").isSuccess else { return false }
        _ = try command("CWD \(old)")
        return true
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        var files: [RemoteFile]
        if hasMLST {
            let data = try openData("MLSD \(path)", path: path)
            let text = try readAll(data)
            try finish(data, path: path)
            files = FTPListing.parseMLSD(String(decoding: text, as: UTF8.self), in: path)
        } else {
            // -a shows dotfiles (.htaccess!), which many servers hide from a
            // bare LIST. A server that takes -a for a path gets plain LIST.
            var data: FTPStream
            do {
                data = try openData("LIST -a \(path)", path: path)
            } catch {
                data = try openData("LIST \(path)", path: path)
            }
            let text = try readAll(data)
            try finish(data, path: path)
            files = FTPListing.parseLIST(String(decoding: text, as: UTF8.self), in: path)
        }
        // Links to folders are listed as links; find out what they point to.
        for i in files.indices where files[i].isSymlink {
            files[i].isDirectory = try isDirectory(files[i].path)
        }
        return files
    }

    public func stat(_ path: String) async throws -> RemoteFile {
        if hasMLST {
            let r = try command("MLST \(path)")
            guard r.isSuccess else { throw failure(r, path: path) }
            // 250-Listing\n <facts>; <path>\n250 End. Some servers prefix
            // the facts line with the code ("250- type=…") instead of a space.
            let factsLine = r.text.split(separator: "\n").dropFirst().dropLast()
                .map { $0.drop { $0.isNumber }.drop { $0 == "-" || $0 == " " } }
                .first { $0.contains("=") && $0.contains(";") }
            guard let factsLine, var file = FTPListing.parseMLSD(String(factsLine), in: remoteParent(path)).first
            else { throw RemoteError.failed(String(localized: "Unexpected MLST reply: \(r.text)", bundle: .module)) }
            file.name = remoteName(path)
            file.path = path
            if file.isSymlink { file.isDirectory = try isDirectory(path) }
            return file
        }
        var file = RemoteFile(name: remoteName(path), path: path)
        var found = false
        let size = try command("SIZE \(path)")
        if size.code == 213, let n = UInt64(size.text.dropFirst(4).trimmingCharacters(in: .whitespaces)) {
            file.size = n
            found = true
        }
        let mdtm = try command("MDTM \(path)")
        if mdtm.code == 213 {
            file.modified = FTPListing.parseTimestamp(String(mdtm.text.dropFirst(4)))
            found = true
        }
        if try isDirectory(path) {
            file.isDirectory = true
            found = true
        }
        guard found else { throw RemoteError.noSuchFile(path) }
        return file
    }

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, progress: TransferProgress?) async throws {
        let size = try command("SIZE \(remotePath)")
        let total = size.code == 213 ? UInt64(size.text.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 0 : 0

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw RemoteError.failed(String(localized: "Can't write \(localURL.path).", bundle: .module))
        }
        let out = try FileHandle(forWritingTo: localURL)
        var completed = false
        defer {
            try? out.close()
            if !completed { try? FileManager.default.removeItem(at: localURL) }
        }

        let data = try openData("RETR \(remotePath)", path: remotePath)
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        var done: UInt64 = 0
        progress?(0, total)
        do {
            while true {
                try Task.checkCancellation()
                let n = try data.read(&buffer)
                if n == 0 { break }
                try out.write(contentsOf: buffer[..<n])
                done += UInt64(n)
                progress?(done, total)
            }
        } catch {
            abort(data)
            throw error is CancellationError ? error : RemoteError.failed(error.localizedDescription)
        }
        try finish(data, path: remotePath)
        completed = true
    }

    public func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: TransferProgress?) async throws {
        if !overwrite, try await exists(remotePath) { throw RemoteError.alreadyExists(remotePath) }
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        let total = UInt64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let data = try openData("STOR \(remotePath)", path: remotePath)
        var done: UInt64 = 0
        progress?(0, total)
        do {
            while let chunk = try input.read(upToCount: 1 << 18), !chunk.isEmpty {
                try Task.checkCancellation()
                try data.write(chunk)
                done += UInt64(chunk.count)
                progress?(done, total)
            }
        } catch {
            abort(data)
            throw error is CancellationError ? error : RemoteError.failed(error.localizedDescription)
        }
        try finish(data, path: remotePath)
    }

    // MARK: Changing things

    public func mkdir(_ path: String) async throws {
        let r = try command("MKD \(path)")
        guard r.isSuccess else {
            if try await exists(path) { throw RemoteError.alreadyExists(path) }
            throw failure(r, path: path)
        }
    }

    public func rename(_ from: String, to: String) async throws {
        if try await exists(to) { throw RemoteError.alreadyExists(to) }
        let rnfr = try command("RNFR \(from)")
        guard rnfr.code == 350 else { throw failure(rnfr, path: from) }
        let rnto = try command("RNTO \(to)")
        guard rnto.isSuccess else { throw failure(rnto, path: to) }
    }

    public func chmod(_ path: String, permissions: UInt32) async throws {
        let r = try command("SITE CHMOD \(String(permissions & 0o7777, radix: 8)) \(path)")
        guard r.isSuccess else { throw RemoteError.unsupported(String(localized: "The server didn't change the permissions: \(r.text)", bundle: .module)) }
    }

    public func remove(_ path: String) async throws {
        let r = try command("DELE \(path)")
        guard r.isSuccess else { throw failure(r, path: path) }
    }

    public func rmdir(_ path: String) async throws {
        let r = try command("RMD \(path)")
        guard r.isSuccess else { throw failure(r, path: path) }
    }

    public func createFile(_ path: String) async throws {
        if try await exists(path) { throw RemoteError.alreadyExists(path) }
        let data = try openData("STOR \(path)", path: path)
        try finish(data, path: path)
    }

    /// FTP can't copy on the server, so the file makes a round trip through
    /// a temp file (not memory: it may be large).
    public func copyFile(_ from: String, to: String) async throws {
        if try await exists(to) { throw RemoteError.alreadyExists(to) }
        let temp = FileManager.default.temporaryDirectory.appending(path: "edith-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await download(from, to: temp, progress: nil)
        try await upload(temp, to: to, overwrite: true, progress: nil)
    }

    public func exec(_ command: String) async throws -> ExecResult {
        throw RemoteError.unsupported(String(localized: "FTP servers can't run commands.", bundle: .module))
    }
}

// MARK: - Listings

enum FTPListing {
    /// MLSD lines: `type=file;size=12;modify=20261103120000; name`.
    static func parseMLSD(_ text: String, in directory: String) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" { return nil }
            let isLink = type.hasPrefix("os.unix=symlink") || type.hasPrefix("os.unix=slink")
            let isDir = type == "dir"
            var mode: UInt32 = facts["unix.mode"].flatMap { UInt32($0, radix: 8) } ?? 0
            if mode != 0 || isDir || isLink {
                mode |= isLink ? 0o120000 : isDir ? 0o040000 : 0o100000
            }
            return RemoteFile(
                name: (name as NSString).lastPathComponent,
                path: remoteJoin(directory, (name as NSString).lastPathComponent),
                size: facts["size"].flatMap { UInt64($0) } ?? 0,
                isDirectory: isDir,
                isSymlink: isLink,
                mode: mode,
                modified: facts["modify"].flatMap(parseTimestamp),
                owner: facts["unix.ownername"] ?? facts["unix.owner"] ?? facts["unix.uid"] ?? "",
                group: facts["unix.groupname"] ?? facts["unix.group"] ?? facts["unix.gid"] ?? ""
            )
        }
    }

    /// `ls -l` style lines, as nearly every server's LIST sends them.
    static func parseLIST(_ text: String, in directory: String, now: Date = .now) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            // perms links owner group size month day time-or-year name
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let type = fields[0].first, "-dl".contains(type), fields[0].count >= 10 else { return nil }
            var name = String(fields[8])
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard name != ".", name != ".." else { return nil }

            var mode: UInt32 = type == "d" ? 0o040000 : type == "l" ? 0o120000 : 0o100000
            let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
            for (i, c) in fields[0].dropFirst().prefix(9).enumerated() where c != "-" { mode |= bits[i] }

            return RemoteFile(
                name: name,
                path: remoteJoin(directory, name),
                size: UInt64(fields[4]) ?? 0,
                isDirectory: type == "d",
                isSymlink: type == "l",
                mode: mode,
                modified: parseListDate(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now),
                owner: String(fields[2]),
                group: String(fields[3])
            )
        }
    }

    /// `YYYYMMDDHHMMSS[.sss]`, in UTC (MLSD and MDTM).
    static func parseTimestamp(_ s: String) -> Date? {
        let digits = s.trimmingCharacters(in: .whitespaces).prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len))! }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (n(0, 4), n(4, 2), n(6, 2), n(8, 2), n(10, 2), n(12, 2))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: c)
    }

    /// `Nov  3 14:05` (this year, or last if that's in the future) or `Nov  3  2024`.
    static func parseListDate(month: Substring, day: Substring, timeOrYear: Substring, now: Date) -> Date? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let m = months.firstIndex(of: month.lowercased()), let d = Int(day) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var c = DateComponents(month: m + 1, day: d)
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return nil }
            (c.hour, c.minute) = (hm[0], hm[1])
            c.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: c), date > now.addingTimeInterval(86400) {
                c.year! -= 1
            }
        } else {
            c.year = Int(timeOrYear)
        }
        return calendar.date(from: c)
    }
}

// MARK: - Sockets and TLS

/// OpenSSL client context, shared by a connection's control and data streams.
final class TLSContext: @unchecked Sendable {
    let ctx: OpaquePointer

    init() throws {
        guard let ctx = SSL_CTX_new(TLS_client_method()) else { throw RemoteError.failed(String(localized: "Couldn't set up TLS.", bundle: .module)) }
        // Verification happens with the macOS trust store, after the handshake.
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
        SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, Int(SSL_SESS_CACHE_CLIENT), nil)
        self.ctx = ctx
    }

    deinit {
        SSL_CTX_free(ctx)
    }
}

/// A socket, plain or wrapped in TLS, with line reading for the control
/// connection.
final class FTPStream: @unchecked Sendable {
    /// -1 once closed. Closing twice would close whatever socket the system
    /// handed that number to in between, another connection's perhaps.
    private(set) var fd: Int32
    private var ssl: OpaquePointer?
    private var pending = [UInt8]()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    func setTimeout(_ timeout: Duration) {
        var tv = timeval(tv_sec: Int(timeout.components.seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func startTLS(_ context: TLSContext, host: String, resuming session: OpaquePointer?) throws {
        guard let ssl = SSL_new(context.ctx) else { throw RemoteError.failed(String(localized: "Couldn't start TLS.", bundle: .module)) }
        SSL_set_fd(ssl, fd)
        // SNI, unless the host is an IP address (where it's not allowed).
        if inet_addr(host) == INADDR_NONE && !host.contains(":") {
            // OpenSSL copies the name, so the pointer only has to last the call.
            _ = host.withCString { SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, Int(TLSEXT_NAMETYPE_host_name), UnsafeMutableRawPointer(mutating: $0)) }
        }
        if let session { SSL_set_session(ssl, session) }
        guard SSL_connect(ssl) == 1 else {
            let message = Self.lastError()
            SSL_free(ssl)
            throw RemoteError.connectionFailed(String(localized: "TLS handshake failed: \(message)", bundle: .module))
        }
        self.ssl = ssl
    }

    /// The session to resume on data connections. Read fresh each time:
    /// with TLS 1.3 the ticket arrives after the handshake.
    var session: OpaquePointer? {
        ssl.flatMap { SSL_get_session($0) }
    }

    var sessionReused: Bool {
        ssl.map { SSL_session_reused($0) == 1 } ?? false
    }

    func peerCertificates() -> [SecCertificate] {
        guard let ssl, let chain = SSL_get_peer_cert_chain(ssl) else { return [] }
        return (0..<OPENSSL_sk_num(chain)).compactMap { i in
            guard let cert = OPENSSL_sk_value(chain, i) else { return nil }
            var der: UnsafeMutablePointer<UInt8>?
            let length = i2d_X509(OpaquePointer(cert), &der)
            guard length > 0, let der else { return nil }
            defer { CRYPTO_free(der, #file, #line) }
            return SecCertificateCreateWithData(nil, Data(bytes: der, count: Int(length)) as CFData)
        }
    }

    func read(_ buffer: inout [UInt8]) throws -> Int {
        let n: Int = buffer.withUnsafeMutableBytes { raw in
            if let ssl {
                return Int(SSL_read(ssl, raw.baseAddress, Int32(raw.count)))
            }
            return Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if n > 0 { return n }
        if let ssl {
            let error = SSL_get_error(ssl, Int32(n))
            if error == SSL_ERROR_ZERO_RETURN { return 0 }
            // Many servers close data connections without a TLS close_notify.
            if error == SSL_ERROR_SYSCALL && errno == 0 { return 0 }
            throw RemoteError.connectionFailed(String(localized: "TLS read failed: \(Self.lastError())", bundle: .module))
        }
        if n == 0 { return 0 }
        throw RemoteError.connectionFailed(errno == EAGAIN ? "The server stopped responding." : String(cString: strerror(errno)))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let rest = raw.count - offset
                let n: Int = if let ssl {
                    Int(SSL_write(ssl, raw.baseAddress! + offset, Int32(rest)))
                } else {
                    Darwin.write(fd, raw.baseAddress! + offset, rest)
                }
                guard n > 0 else { throw RemoteError.connectionFailed(String(localized: "Writing to the server failed.", bundle: .module)) }
                offset += n
            }
        }
    }

    func writeLine(_ line: String) throws {
        try write(Data((line + "\r\n").utf8))
    }

    func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                var line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            let n = try read(&buffer)
            guard n > 0 else { throw RemoteError.connectionFailed(String(localized: "The server closed the connection.", bundle: .module)) }
            pending.append(contentsOf: buffer[..<n])
        }
    }

    func close() {
        if let ssl {
            SSL_shutdown(ssl)
            SSL_free(ssl)
            self.ssl = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private static func lastError() -> String {
        let code = ERR_get_error()
        guard code != 0 else { return "connection closed" }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
