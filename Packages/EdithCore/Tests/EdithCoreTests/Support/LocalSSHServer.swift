// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
@testable import EdithCore

/// A throwaway OpenSSH server for integration tests: `/usr/sbin/sshd` on a
/// free loopback port, running as the current user with public-key auth
/// only, plus an ssh-agent. Started once per test run, stopped at exit.
final class LocalSSHServer: Sendable {
    static let shared: LocalSSHServer? = try? LocalSSHServer()

    let dir: URL
    let port: Int
    let agentSocket: String
    /// known_hosts holding the server's ed25519 key, as after a first `ssh`.
    let knownHosts: URL
    /// Remote directory tests may use; it's `dir/files` on this machine.
    let files: String
    let user = NSUserName()

    /// Client keys, all accepted by the server. The `-enc` ones use passphrase "secret".
    static let keyNames = ["ed25519", "ed25519-enc", "rsa", "rsa-enc", "rsa-pem-enc", "ecdsa"]

    private init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { throw CocoaError(.fileNoSuchFile) }
        // Keep it short: the agent's Unix socket path must stay under 104 bytes.
        dir = FileManager.default.temporaryDirectory.appending(path: "edith-sshd-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appending(path: "keys"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appending(path: "files"), withIntermediateDirectories: true)
        files = dir.appending(path: "files").path
        agentSocket = dir.appending(path: "agent.sock").path
        knownHosts = dir.appending(path: "known_hosts")
        port = try Self.freePort()

        for type in ["ed25519", "rsa", "ecdsa"] {
            try run("/usr/bin/ssh-keygen", ["-q", "-t", type, "-N", "", "-f", dir.appending(path: "host_\(type)").path])
        }
        let keys: [(String, [String])] = [
            ("ed25519", ["-t", "ed25519", "-N", ""]),
            ("ed25519-enc", ["-t", "ed25519", "-N", "secret"]),
            ("rsa", ["-t", "rsa", "-b", "2048", "-N", ""]),
            ("rsa-enc", ["-t", "rsa", "-b", "2048", "-N", "secret"]),
            ("rsa-pem-enc", ["-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "secret"]),
            ("ecdsa", ["-t", "ecdsa", "-b", "256", "-N", ""]),
            ("agent-only", ["-t", "ed25519", "-N", ""]),
        ]
        for (name, args) in keys {
            try run("/usr/bin/ssh-keygen", ["-q", "-C", name, "-f", dir.appending(path: "keys/\(name)").path] + args)
        }
        let authorized = try keys.map { try String(contentsOf: dir.appending(path: "keys/\($0.0).pub"), encoding: .utf8) }.joined()
        try authorized.write(to: dir.appending(path: "authorized_keys"), atomically: true, encoding: .utf8)

        let hostKey = try String(contentsOf: dir.appending(path: "host_ed25519.pub"), encoding: .utf8).split(separator: " ")
        try "[127.0.0.1]:\(port) \(hostKey[0]) \(hostKey[1])\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(dir.path)/host_ed25519
        HostKey \(dir.path)/host_rsa
        HostKey \(dir.path)/host_ecdsa
        AuthorizedKeysFile \(dir.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(dir.path)/sshd.pid
        Subsystem sftp /usr/libexec/sftp-server
        """
        try config.write(to: dir.appending(path: "sshd_config"), atomically: true, encoding: .utf8)

        try run("/usr/sbin/sshd", ["-f", dir.appending(path: "sshd_config").path, "-E", dir.appending(path: "sshd.log").path])
        let agentEnv = try run("/usr/bin/ssh-agent", ["-a", agentSocket])
        try agentEnv.write(to: dir.appending(path: "agent.env"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = agentSocket
        try run("/usr/bin/ssh-add", ["-q", dir.appending(path: "keys/agent-only").path], environment: env)

        try waitForPort()
        Self.cleanupDir = dir
        atexit {
            guard let dir = LocalSSHServer.cleanupDir else { return }
            if let pid = try? String(contentsOf: dir.appending(path: "sshd.pid"), encoding: .utf8) {
                kill(pid_t(pid.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, SIGTERM)
            }
            if let env = try? String(contentsOf: dir.appending(path: "agent.env"), encoding: .utf8),
               let match = env.firstMatch(of: /SSH_AGENT_PID=(\d+)/) {
                kill(pid_t(match.1) ?? 0, SIGTERM)
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    nonisolated(unsafe) private static var cleanupDir: URL?

    func keyPath(_ name: String) -> String {
        dir.appending(path: "keys/\(name)").path
    }

    /// A host key store that knows this server and writes accepted keys
    /// into a fresh file of its own.
    func hostKeyStore(knowsServer: Bool = true) -> HostKeyStore {
        HostKeyStore(
            userFile: knowsServer ? knownHosts : dir.appending(path: "empty_known_hosts"),
            appFile: dir.appending(path: "app_known_hosts-\(UUID().uuidString)")
        )
    }

    /// `ssh-keygen -l` for one of the server's host keys.
    func fingerprint(_ type: String) throws -> String {
        let out = try run("/usr/bin/ssh-keygen", ["-lf", dir.appending(path: "host_\(type).pub").path])
        return String(out.split(separator: " ")[1])
    }

    func connect(
        key: String? = "ed25519",
        passphrase: String? = nil,
        hostKeys: HostKeyStore? = nil,
        approve: @escaping HostKeyApprover = { _ in false }
    ) async throws -> SFTPClient {
        let client = SFTPClient(hostKeys: hostKeys ?? hostKeyStore())
        let credentials = SSHCredentials(
            username: user,
            keyFile: key.map(keyPath),
            passphrase: passphrase,
            agentSocket: agentSocket
        )
        try await client.connect(host: "127.0.0.1", port: port, credentials: credentials, approveHostKey: approve)
        return client
    }

    /// A fresh, empty remote directory for one test.
    func scratch() throws -> String {
        let path = files + "/" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard bind(fd, sa, len) == 0, getsockname(fd, sa, &len) == 0 else { throw CocoaError(.featureUnsupported) }
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func waitForPort() throws {
        for _ in 0..<50 {
            if let fd = try? openSocket(host: "127.0.0.1", port: port, timeout: .seconds(1)) {
                close(fd)
                return
            }
            usleep(100_000)
        }
        throw CocoaError(.featureUnsupported)
    }

    /// Runs a tool to completion and returns its stdout.
    @discardableResult
    private func run(_ tool: String, _ args: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }
}
