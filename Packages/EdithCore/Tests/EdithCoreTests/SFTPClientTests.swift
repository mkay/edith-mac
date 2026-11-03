// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

/// SFTPClient against a real OpenSSH sshd on loopback. Serialized: sshd
/// drops connections when too many arrive unauthenticated at once.
@Suite(.serialized, .enabled(if: LocalSSHServer.shared != nil, "needs /usr/sbin/sshd"))
struct SFTPClientTests {
    let server = LocalSSHServer.shared!

    // MARK: Authentication

    @Test(arguments: LocalSSHServer.keyNames)
    func keyFileAuth(key: String) async throws {
        let client = try await server.connect(key: key, passphrase: key.hasSuffix("-enc") ? "secret" : nil)
        #expect(await client.isConnected)
        _ = try await client.list(server.files)
        await client.close()
        #expect(await !client.isConnected)
    }

    @Test func agentAuthWhenNoKeyOrPassword() async throws {
        let client = try await server.connect(key: nil)
        #expect(await client.isConnected)
        await client.close()
    }

    @Test func wrongPassphraseFails() async throws {
        await #expect {
            _ = try await server.connect(key: "ed25519-enc", passphrase: "wrong")
        } throws: { error in
            if case RemoteError.authenticationFailed = error { true } else { false }
        }
    }

    @Test func passwordIsRefusedWhenServerOnlyTakesKeys() async throws {
        let client = SFTPClient(hostKeys: server.hostKeyStore())
        await #expect {
            try await client.connect(host: "127.0.0.1", port: server.port,
                                     credentials: SSHCredentials(username: server.user, password: "x"),
                                     approveHostKey: { _ in false })
        } throws: { error in
            (error as? RemoteError)?.errorDescription?.contains("doesn't accept passwords") == true
        }
    }

    @Test func connectionRefusedIsReported() async throws {
        let client = SFTPClient(hostKeys: server.hostKeyStore())
        await #expect {
            try await client.connect(host: "127.0.0.1", port: 1, credentials: SSHCredentials(username: "x"), approveHostKey: { _ in false })
        } throws: { error in
            if case RemoteError.connectionFailed = error { true } else { false }
        }
    }

    // MARK: Host keys

    @Test func unknownHostKeyIsOfferedAndRememberedWhenAccepted() async throws {
        let store = server.hostKeyStore(knowsServer: false)
        let asked = Challenges()

        await #expect(throws: RemoteError.hostKeyRejected) {
            _ = try await server.connect(hostKeys: store) { await asked.record($0); return false }
        }
        let challenge = try #require(await asked.all.first)
        #expect(challenge.keyType == "ssh-ed25519")
        #expect(challenge.fingerprint == (try server.fingerprint("ed25519")))
        #expect(challenge.otherKnownTypes.isEmpty)

        let client = try await server.connect(hostKeys: store) { await asked.record($0); return true }
        await client.close()
        // Accepted once, it isn't asked about again.
        let again = try await server.connect(hostKeys: store) { await asked.record($0); return false }
        await again.close()
        #expect(await asked.all.count == 2)
    }

    @Test func changedHostKeyFailsWithoutAsking() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bogus = Data(repeating: 7, count: 51).base64EncodedString()
        try "[127.0.0.1]:\(server.port) ssh-ed25519 \(bogus)\n".write(to: dir.appending(path: "kh"), atomically: true, encoding: .utf8)
        let store = HostKeyStore(userFile: dir.appending(path: "kh"), appFile: dir.appending(path: "app"))

        await #expect {
            _ = try await server.connect(hostKeys: store) { _ in
                Issue.record("must not ask about a changed key")
                return true
            }
        } throws: { error in
            if case RemoteError.hostKeyChanged(_, "ssh-ed25519", _) = error { true } else { false }
        }
    }

    @Test func knownKeyTypeIsNegotiatedFirst() async throws {
        // Only the RSA host key is on record; the client has to ask for RSA
        // rather than its usual ed25519 first, or the host looks unknown.
        let dir = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rsa = try String(contentsOf: server.dir.appending(path: "host_rsa.pub"), encoding: .utf8).split(separator: " ")
        try "[127.0.0.1]:\(server.port) \(rsa[0]) \(rsa[1])\n".write(to: dir.appending(path: "kh"), atomically: true, encoding: .utf8)
        let store = HostKeyStore(userFile: dir.appending(path: "kh"), appFile: dir.appending(path: "app"))

        let client = try await server.connect(hostKeys: store) { _ in
            Issue.record("the RSA key is on record and must match")
            return false
        }
        await client.close()
    }

    // MARK: Files

    @Test func listStatAndNormalize() async throws {
        let client = try await server.connect()
        let dir = try server.scratch()
        try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/a.txt"))
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link-to-sub", withDestinationPath: dir + "/sub")

        let entries = try await client.list(dir).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["a.txt", "link-to-sub", "sub"])
        #expect(entries[0].size == 5 && !entries[0].isDirectory)
        #expect(entries[0].owner == server.user)
        #expect(entries[0].modified != nil)
        #expect(entries[1].isSymlink && entries[1].isDirectory)
        #expect(entries[2].isDirectory && !entries[2].isSymlink)

        #expect(try await client.stat(dir + "/a.txt").size == 5)
        // realpath(3), not resolvingSymlinksInPath, which strips /private.
        let real = String(cString: realpath(dir, nil))
        #expect(try await client.normalize(dir + "/sub/..") == real)
        #expect(try await client.normalize(".") == NSHomeDirectory())
        await #expect(throws: RemoteError.noSuchFile(dir + "/missing")) { _ = try await client.stat(dir + "/missing") }
        await #expect(throws: RemoteError.noSuchFile(dir + "/missing")) { _ = try await client.list(dir + "/missing") }
        await client.close()
    }

    @Test func uploadDownloadRoundTrip() async throws {
        let client = try await server.connect()
        let dir = try server.scratch()
        let local = FileManager.default.temporaryDirectory.appending(path: "up-\(UUID().uuidString)")
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: local)

        let ups = ProgressLog()
        try await client.upload(local, to: dir + "/blob.bin", overwrite: false) { ups.add($0, $1) }
        #expect(ups.ended(UInt64(payload.count), UInt64(payload.count)))
        #expect(ups.isMonotonic)

        await #expect(throws: RemoteError.alreadyExists(dir + "/blob.bin")) {
            try await client.upload(local, to: dir + "/blob.bin", overwrite: false, progress: nil)
        }
        try await client.upload(local, to: dir + "/blob.bin", overwrite: true, progress: nil)

        let back = FileManager.default.temporaryDirectory.appending(path: "down-\(UUID().uuidString)/nested/blob.bin")
        let downs = ProgressLog()
        try await client.download(dir + "/blob.bin", to: back) { downs.add($0, $1) }
        #expect(try Data(contentsOf: back) == payload)
        #expect(downs.ended(UInt64(payload.count), UInt64(payload.count)))
        await client.close()
    }

    @Test func changingThings() async throws {
        let client = try await server.connect()
        let dir = try server.scratch()

        try await client.mkdir(dir + "/d")
        await #expect(throws: RemoteError.alreadyExists(dir + "/d")) { try await client.mkdir(dir + "/d") }

        try await client.createFile(dir + "/d/f.txt")
        await #expect(throws: RemoteError.alreadyExists(dir + "/d/f.txt")) { try await client.createFile(dir + "/d/f.txt") }
        #expect(try await client.stat(dir + "/d/f.txt").size == 0)

        try await client.chmod(dir + "/d/f.txt", permissions: 0o600)
        #expect(try await client.stat(dir + "/d/f.txt").permissionsString == "-rw-------")

        try await client.rename(dir + "/d/f.txt", to: dir + "/d/g.txt")
        try await client.createFile(dir + "/d/h.txt")
        await #expect(throws: RemoteError.alreadyExists(dir + "/d/g.txt")) {
            try await client.rename(dir + "/d/h.txt", to: dir + "/d/g.txt")
        }

        try Data("copy me".utf8).write(to: URL(fileURLWithPath: dir + "/d/g.txt"))
        try await client.copyFile(dir + "/d/g.txt", to: dir + "/d/copy.txt")
        #expect(try String(contentsOfFile: dir + "/d/copy.txt", encoding: .utf8) == "copy me")
        #expect(try await client.stat(dir + "/d/copy.txt").permissions == 0o600, "a copy keeps the source's permissions")

        try await client.remove(dir + "/d/h.txt")
        await #expect(throws: RemoteError.noSuchFile(dir + "/d/h.txt")) { try await client.remove(dir + "/d/h.txt") }
        await #expect { try await client.rmdir(dir + "/d") } throws: { _ in true }

        try await client.copyRecursive(dir + "/d", to: dir + "/d2")
        #expect(try await client.list(dir + "/d2").map(\.name).sorted() == ["copy.txt", "g.txt"])
        await #expect(throws: RemoteError.alreadyExists(dir + "/d2")) { try await client.copyRecursive(dir + "/d", to: dir + "/d2") }

        try await client.removeRecursive(dir + "/d")
        #expect(try await !client.exists(dir + "/d"))
        #expect(try await client.exists(dir + "/d2/g.txt"))
        await client.close()
    }

    @Test func treeTransfers() async throws {
        let client = try await server.connect()
        let dir = try server.scratch()
        let local = FileManager.default.temporaryDirectory.appending(path: "tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: local.appending(path: "top.txt"))
        try Data(count: 2000).write(to: local.appending(path: "a/b/deep.txt"))

        let ups = ProgressLog()
        try await client.uploadDirectory(local, to: dir + "/up", overwrite: false) { ups.add($0, $1) }
        #expect(ups.ended(3000, 3000))
        #expect(FileManager.default.fileExists(atPath: dir + "/up/a/b/deep.txt"))
        await #expect(throws: RemoteError.alreadyExists(dir + "/up")) {
            try await client.uploadDirectory(local, to: dir + "/up", overwrite: false, progress: nil)
        }

        let back = FileManager.default.temporaryDirectory.appending(path: "treeback-\(UUID().uuidString)")
        let downs = ProgressLog()
        try await client.downloadTree(dir + "/up", to: back) { downs.add($0, $1) }
        #expect(try Data(contentsOf: back.appending(path: "a/b/deep.txt")).count == 2000)
        #expect(downs.ended(3000, 3000))
        #expect(try await client.treeSize(dir + "/up") == 3000)
        await client.close()
    }

    @Test func cancelledDownloadStopsAndLeavesNoPartialFile() async throws {
        let client = try await server.connect()
        let dir = try server.scratch()
        try Data(count: 64 << 20).write(to: URL(fileURLWithPath: dir + "/big.bin"))
        let local = FileManager.default.temporaryDirectory.appending(path: "cancel-\(UUID().uuidString).bin")

        let task = Task {
            try await client.download(dir + "/big.bin", to: local) { done, _ in
                if done >= 2 << 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: local.path))
        // The connection is still usable afterwards.
        #expect(try await client.stat(dir + "/big.bin").size == 64 << 20)
        await client.close()
    }

    // MARK: Exec

    @Test func execReportsStatusAndKeepsStreamsApart() async throws {
        let client = try await server.connect()
        #expect(await client.canExec)

        let ok = try await client.exec("echo out; echo err >&2")
        #expect(ok == ExecResult(status: 0, stdout: "out\n", stderr: "err\n"))
        #expect(try await client.exec("exit 3").status == 3)

        // Megabytes on stderr before any stdout: must not deadlock.
        let flood = try await client.exec("head -c 3000000 /dev/zero | tr '\\0' x >&2; echo done")
        #expect(flood.stdout == "done\n")
        #expect(flood.stderr.count == 3_000_000)
        await client.close()
    }
}

private actor Challenges {
    var all: [HostKeyChallenge] = []
    func record(_ c: HostKeyChallenge) { all.append(c) }
}

/// Collects progress callbacks, which arrive on the client's queue.
private final class ProgressLog: @unchecked Sendable {
    private var values: [(UInt64, UInt64)] = []
    private let lock = NSLock()

    func add(_ done: UInt64, _ total: UInt64) { lock.withLock { values.append((done, total)) } }
    /// The last report was (done, total).
    func ended(_ done: some BinaryInteger, _ total: some BinaryInteger) -> Bool {
        lock.withLock { values.last.map { $0.0 == UInt64(done) && $0.1 == UInt64(total) } ?? false }
    }
    var isMonotonic: Bool {
        lock.withLock { zip(values, values.dropFirst()).allSatisfy { $0.0 <= $1.0 } }
    }
}
