// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

// MARK: - Parsing

@Test func parsesUnixListing() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
    let text = """
    total 12\r
    drwxr-xr-x    2 www  www      4096 Oct 30 09:15 css\r
    -rw-r--r--    1 www  www       512 Nov  3 11:00 index.php\r
    -rw-------    1 www  www        42 Dec 24 18:00 .htaccess\r
    lrwxrwxrwx    1 www  www         5 Jan  2  2024 current -> css\r
    -rw-r--r--    1 www  www         1 Feb  1  2025 name with spaces.txt\r
    """
    let files = FTPListing.parseLIST(text, in: "/srv", now: now)
    #expect(files.map(\.name) == ["css", "index.php", ".htaccess", "current", "name with spaces.txt"])
    #expect(files[0].isDirectory && files[0].permissionsString == "drwxr-xr-x")
    #expect(files[1].size == 512 && files[1].owner == "www" && files[1].path == "/srv/index.php")
    #expect(files[3].isSymlink && files[3].name == "current", "the link target isn't part of the name")

    let calendar = Calendar(identifier: .gregorian)
    // "Dec 24 18:00" would be in the future this year, so it's last year's.
    #expect(calendar.component(.year, from: files[2].modified!) == 2025)
    #expect(calendar.component(.year, from: files[3].modified!) == 2024)
}

@Test func parsesMLSD() throws {
    let text = """
    type=cdir;modify=20261103120000; .\r
    type=dir;modify=20261030091500;unix.mode=0755;unix.owner=www; css\r
    type=file;size=512;modify=20261103110000;unix.mode=0644; index.php\r
    type=OS.unix=symlink;size=3;modify=20240102000000; current\r
    """
    let files = FTPListing.parseMLSD(text, in: "/srv")
    #expect(files.map(\.name) == ["css", "index.php", "current"])
    #expect(files[0].isDirectory && files[0].permissions == 0o755 && files[0].owner == "www")
    #expect(files[1].size == 512 && files[1].permissionsString == "-rw-r--r--")
    #expect(files[2].isSymlink)
    #expect(files[1].modified == FTPListing.parseTimestamp("20261103110000"))
    #expect(FTPListing.parseTimestamp("20261103110000.123") == FTPListing.parseTimestamp("20261103110000"))
    #expect(FTPListing.parseTimestamp("garbage") == nil)
}

// MARK: - Against the test server

@Suite(.serialized, .enabled(if: LocalFTPServer.available, "needs /usr/bin/python3"))
struct FTPClientTests {
    @Test(arguments: [true, false])
    func browsingAndFileOperations(mlsd: Bool) async throws {
        let server = try LocalFTPServer(mlsd: mlsd)
        try server.write("<?php", to: "/www/index.php")
        try server.write("deny", to: "/www/.htaccess")
        try FileManager.default.createDirectory(atPath: server.root + "/www/css", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: server.root + "/www/styles", withDestinationPath: server.root + "/www/css")
        let ftp = try await server.connect()

        #expect(try await ftp.normalize(".") == "/")
        let names = try await ftp.list("/www").map(\.name).sorted()
        #expect(names == [".htaccess", "css", "index.php", "styles"], "dotfiles show without MLSD too (LIST -a)")
        let link = try #require(try await ftp.list("/www").first { $0.name == "styles" })
        #expect(link.isSymlink && link.isDirectory)

        let stat = try await ftp.stat("/www/index.php")
        #expect(stat.size == 5 && !stat.isDirectory && stat.modified != nil)
        #expect(try await ftp.stat("/www/css").isDirectory)
        await #expect(throws: RemoteError.noSuchFile("/www/missing")) { _ = try await ftp.stat("/www/missing") }

        try await ftp.mkdir("/www/new")
        await #expect(throws: RemoteError.alreadyExists("/www/new")) { try await ftp.mkdir("/www/new") }
        try await ftp.createFile("/www/new/a.txt")
        try await ftp.rename("/www/new/a.txt", to: "/www/new/b.txt")
        await #expect(throws: RemoteError.alreadyExists("/www/index.php")) { try await ftp.rename("/www/new/b.txt", to: "/www/index.php") }
        try await ftp.chmod("/www/index.php", permissions: 0o600)
        let attrs = try FileManager.default.attributesOfItem(atPath: server.root + "/www/index.php")
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        try await ftp.copyFile("/www/index.php", to: "/www/new/copy.php")
        #expect(try String(contentsOfFile: server.root + "/www/new/copy.php", encoding: .utf8) == "<?php")
        try await ftp.removeRecursive("/www/new")
        #expect(!FileManager.default.fileExists(atPath: server.root + "/www/new"))
        await ftp.close()
    }

    @Test func transfersWithProgress() async throws {
        let server = try LocalFTPServer()
        let ftp = try await server.connect()
        let payload = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let local = FileManager.default.temporaryDirectory.appending(path: "ftp-up-\(UUID().uuidString)")
        try payload.write(to: local)

        let last = LastProgress()
        try await ftp.upload(local, to: "/blob.bin", overwrite: false) { last.set($0, $1) }
        #expect(last.value == [2_000_000, 2_000_000])
        await #expect(throws: RemoteError.alreadyExists("/blob.bin")) { try await ftp.upload(local, to: "/blob.bin", overwrite: false, progress: nil) }

        let back = FileManager.default.temporaryDirectory.appending(path: "ftp-down-\(UUID().uuidString)")
        try await ftp.download("/blob.bin", to: back) { last.set($0, $1) }
        #expect(try Data(contentsOf: back) == payload)
        #expect(last.value == [2_000_000, 2_000_000])
        await ftp.close()
    }

    @Test func pasvAddressesAreIgnoredInFavourOfTheHost() async throws {
        // The server's PASV reply names 10.255.255.1, which isn't reachable.
        let server = try LocalFTPServer(epsv: false)
        try server.write("x", to: "/f.txt")
        let ftp = try await server.connect()
        #expect(try await ftp.list("/").map(\.name) == ["f.txt"])
        await ftp.close()
    }

    @Test func cancelledDownloadLeavesConnectionUsable() async throws {
        let server = try LocalFTPServer()
        try Data(count: 40 << 20).write(to: URL(fileURLWithPath: server.root + "/big.bin"))
        let ftp = try await server.connect()
        let local = FileManager.default.temporaryDirectory.appending(path: "ftp-cancel-\(UUID().uuidString)")
        let task = Task {
            try await ftp.download("/big.bin", to: local) { done, _ in
                if done > 1 << 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: local.path))
        #expect(try await ftp.stat("/big.bin").size == 40 << 20)
        await ftp.close()
    }

    @Test func wrongPasswordFails() async throws {
        let server = try LocalFTPServer()
        await #expect {
            _ = try await server.connect(password: "nope")
        } throws: { error in
            if case RemoteError.authenticationFailed = error { true } else { false }
        }
    }

    // MARK: TLS

    @Test func explicitTLSResumesTheSessionOnDataConnections() async throws {
        // Like vsftpd's default: data connections must resume the session.
        let server = try LocalFTPServer(tls: .explicit, requireReuse: true)
        try server.write("secret stuff", to: "/f.txt")
        let store = CertificateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "certs-\(UUID().uuidString).json"))
        let asked = Asked()

        let ftp = try await server.connect(security: .explicitRequired, certificates: store) { challenge in
            await asked.add(challenge)
            return true
        }
        #expect(try await ftp.list("/").map(\.name) == ["f.txt"])
        #expect(await ftp.lastDataSessionReused)
        let back = FileManager.default.temporaryDirectory.appending(path: "ftps-\(UUID().uuidString)")
        try await ftp.download("/f.txt", to: back, progress: nil)
        #expect(try String(contentsOf: back, encoding: .utf8) == "secret stuff")
        await ftp.close()

        let challenge = try #require(await asked.all.first)
        #expect(challenge.subject == "localhost")
        #expect(challenge.fingerprint.count == 95, "32 hex pairs with colons")

        // Accepted once, the same certificate isn't asked about again.
        let again = try await server.connect(security: .explicitRequired, certificates: store) { _ in
            Issue.record("asked twice")
            return false
        }
        await again.close()
    }

    @Test func implicitTLS() async throws {
        let server = try LocalFTPServer(tls: .implicit)
        try server.write("x", to: "/f.txt")
        let ftp = try await server.connect(security: .implicit)
        #expect(try await ftp.list("/").map(\.name) == ["f.txt"])
        await ftp.close()
    }

    @Test func rejectedCertificateStopsTheConnection() async throws {
        let server = try LocalFTPServer(tls: .explicit)
        await #expect(throws: RemoteError.hostKeyRejected) {
            _ = try await server.connect(security: .explicitRequired) { _ in false }
        }
    }

    @Test func optionalTLSFallsBackRequiredDoesNot() async throws {
        let server = try LocalFTPServer(tls: .none)
        let ftp = try await server.connect(security: .explicitOptional)
        _ = try await ftp.list("/")
        await ftp.close()
        await #expect {
            _ = try await server.connect(security: .explicitRequired)
        } throws: { error in
            if case RemoteError.connectionFailed = error { true } else { false }
        }
    }
}

private actor Asked {
    var all: [CertificateChallenge] = []
    func add(_ c: CertificateChallenge) { all.append(c) }
}

private final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt64] = []
    func set(_ done: UInt64, _ total: UInt64) { lock.withLock { stored = [done, total] } }
    var value: [UInt64] { lock.withLock { stored } }
}
