// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import EdithCore

/// The Python FTP server next to this file, run for one test. It stops when
/// this object goes away (or the test process does): it exits when its
/// stdin closes.
final class LocalFTPServer: @unchecked Sendable {
    enum TLS { case none, explicit, implicit }

    let port: Int
    let root: String
    private let process: Process
    private let stdin: Pipe

    static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    /// A self-signed certificate for localhost, made once per test run.
    private static let certificate: (cert: String, key: String)? = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "edith-ftp-cert-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cert = dir.appending(path: "cert.pem").path, key = dir.appending(path: "key.pem").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? (cert, key) : nil
    }()

    init(tls: TLS = .none, mlsd: Bool = true, epsv: Bool = true, requireReuse: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "edith-ftp-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "ftpserver.py").path
        var args = ["-I", script, "--root", root]
        if tls != .none {
            guard let c = Self.certificate else { throw CocoaError(.featureUnsupported) }
            args += ["--cert", c.cert, "--key", c.key]
            if tls == .implicit { args.append("--implicit") }
        }
        if !mlsd { args.append("--no-mlsd") }
        if !epsv { args.append("--no-epsv") }
        if requireReuse { args.append("--require-reuse") }

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = args
        stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        // "ready <port>"
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw CocoaError(.executableLoad) }
            line.append(chunk)
        }
        guard let port = String(decoding: line, as: UTF8.self).split(separator: " ").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { throw CocoaError(.executableLoad) }
        self.port = port
    }

    deinit {
        // Not waitUntilExit(): it relies on a run loop, and on Swift's
        // cooperative threads it never sees the exit and hangs forever.
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: root)
    }

    func connect(security: FTPClient.Security = .none, password: String = "secret",
                 certificates: CertificateStore? = nil,
                 approve: @escaping CertificateApprover = { _ in true }) async throws -> FTPClient {
        let store = certificates ?? CertificateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "certs-\(UUID().uuidString).json"))
        let client = FTPClient(certificates: store)
        try await client.connect(host: "127.0.0.1", port: port, username: "test", password: password,
                                 security: security, approveCertificate: approve)
        return client
    }

    func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: root + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
