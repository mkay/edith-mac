// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import SpikeKit

/// Records the server's host key and compares it with known_hosts. Citadel
/// has no known_hosts support of its own, so this is what the app would ship.
final class KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let knownHosts: String
    var keyType = ""
    var fingerprint = ""
    var status = HostKeyStatus.unchecked

    init(host: String, port: Int, knownHosts: String) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)  // "ssh-ed25519 AAAA..."
        let parts = line.split(separator: " ")
        keyType = String(parts[0])
        if let blob = Data(base64Encoded: String(parts[1])) {
            fingerprint = openSSHFingerprint(sha256: Array(SHA256.hash(data: blob)))
        }

        // Plain (unhashed) entries only; good enough for the spike.
        let name = port == 22 ? host : "[\(host)]:\(port)"
        let entries = ((try? String(contentsOfFile: knownHosts, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map { $0.split(separator: " ") }
            .filter { $0.count >= 3 && $0[0].split(separator: ",").contains(Substring(name)) }
        if entries.contains(where: { $0[1] == parts[0] && $0[2] == parts[1] }) {
            status = .match
        } else if entries.contains(where: { $0[1] == parts[0] }) {
            status = .mismatch
        } else {
            status = .notFound
        }
        validationCompletePromise.succeed(())
    }
}

struct CitadelClient: SpikeClient {
    var client: SSHClient?
    var sftp: SFTPClient?

    mutating func connect(_ o: SpikeOptions) async throws -> (keyType: String, fingerprint: String, status: HostKeyStatus) {
        let auth: SSHAuthenticationMethod
        switch o.auth {
        case .password(let pw):
            auth = .passwordBased(username: o.user, password: pw)
        case .key(let path, let passphrase):
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let decryptionKey = passphrase.map { Data($0.utf8) }
            switch try SSHKeyDetection.detectPrivateKeyType(from: text) {
            case .ed25519:
                auth = .ed25519(username: o.user, privateKey: try .init(sshEd25519: text, decryptionKey: decryptionKey))
            case .rsa:
                auth = .rsa(username: o.user, privateKey: try .init(sshRsa: text, decryptionKey: decryptionKey))
            case let other:
                throw SpikeError("Citadel can't load \(other) private keys from a file")
            }
        case .agent:
            throw SpikeError("Citadel has no ssh-agent support")
        }

        let validator = KnownHostsValidator(host: o.host, port: o.port, knownHosts: o.knownHosts)
        client = try await SSHClient.connect(
            host: o.host, port: o.port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(validator),
            reconnect: .never
        )
        sftp = try await client!.openSFTP()
        return (validator.keyType, validator.fingerprint, validator.status)
    }

    mutating func list(_ path: String) async throws -> [(name: String, size: UInt64, isDir: Bool)] {
        let names = try await sftp!.listDirectory(atPath: path)
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { c in
                let isDir = (c.attributes.permissions ?? 0) & 0o170000 == 0o040000
                return (c.filename, c.attributes.size ?? 0, isDir)
            }
    }

    mutating func download(_ remote: String, to local: URL) async throws -> UInt64 {
        let file = try await sftp!.openFile(filePath: remote, flags: .read)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }

        // Citadel issues one read at a time. Keep `depth` reads in flight and
        // write them back in order, as libssh2 does internally.
        let chunk: UInt32 = 32768
        let depth = 16
        var offset: UInt64 = 0
        var total: UInt64 = 0
        var eof = false
        // SFTPFile isn't Sendable, though its reads are safe to overlap.
        nonisolated(unsafe) let shared = file
        while !eof {
            let buffers = try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
                for i in 0..<depth {
                    let at = offset + UInt64(i) * UInt64(chunk)
                    group.addTask { (i, try await shared.read(from: at, length: chunk)) }
                }
                var result = [ByteBuffer?](repeating: nil, count: depth)
                for try await (i, b) in group { result[i] = b }
                return result.map { $0! }
            }
            for b in buffers {
                if b.readableBytes == 0 { eof = true; break }
                out.write(Data(b.readableBytesView))
                total += UInt64(b.readableBytes)
                if b.readableBytes < Int(chunk) { eof = true; break }
            }
            offset += UInt64(depth) * UInt64(chunk)
        }
        try await file.close()
        return total
    }

    mutating func exec(_ command: String) async throws -> (status: Int, stdout: String, stderr: String) {
        // executeCommand only returns output; a non-zero exit is an error,
        // and stdout is lost when that happens.
        do {
            let out = try await client!.executeCommand(command)
            return (0, String(buffer: out), "")
        } catch let failed as SSHClient.CommandFailed {
            return (failed.exitCode, "", "")
        }
    }

    mutating func close() async {
        try? await sftp?.close()
        try? await client?.close()
    }
}

func main() async {
    var client = CitadelClient()
    await runSpike("citadel", &client)
}

await main()
