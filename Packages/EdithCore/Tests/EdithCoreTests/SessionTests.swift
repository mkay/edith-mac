// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

@MainActor
@Suite(.serialized, .enabled(if: LocalSSHServer.shared != nil, "needs /usr/sbin/sshd"))
struct SessionTests {
    let server = LocalSSHServer.shared!

    func connect(initialDirectory: String = "/") async throws -> Session {
        try await Session.connect(to: server.server(initialDirectory: initialDirectory), secret: nil,
                                  hostKeys: server.hostKeyStore(), approveHostKey: { _ in false })
    }

    @Test func reconnectReplacesTheClients() async throws {
        let dir = try server.scratch()
        let session = try await connect(initialDirectory: dir)
        let before = session.client
        #expect(await session.isConnected)
        try await session.reconnect()
        #expect(session.client !== before)
        #expect(await session.isConnected)
        #expect(!(await before.isConnected))
        _ = try await session.client.list(dir)
        await session.close()
    }

    @Test func startDirectoryResolution() async throws {
        let dir = try server.scratch()
        let home = NSHomeDirectory()
        for (initial, expected) in [(dir, dir), ("~", home), ("", "/"), (dir + "/gone", home)] {
            let session = try await connect(initialDirectory: initial)
            #expect(session.home == home)
            #expect(session.startDirectory == expected, "\(initial)")
            await session.close()
        }
    }

    @Test func secretKinds() {
        #expect(Server(authMethod: .password).secretKind == .password)
        #expect(Server(keyFile: "/k", authMethod: .key).secretKind == .none)
        #expect(Server(authMethod: .key).secretKind == .none)
        #expect(Server(keyFile: "/k", authMethod: .keyWithPassphrase).secretKind == .passphrase)
        #expect(Server(serverProtocol: .ftp).secretKind == .password)
    }

    @Test(.enabled(if: LocalFTPServer.available)) func ftpSessions() async throws {
        let ftp = try LocalFTPServer(tls: .explicit)
        try ftp.write("x", to: "/site/index.html")
        let site = Server(host: "127.0.0.1", port: ftp.port, username: "test", serverProtocol: .ftp,
                          ftpEncryption: .explicitRequired, initialDirectory: "/site")
        let certs = CertificateStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "c-\(UUID().uuidString).json"))
        let session = try await Session.connect(to: site, secret: "secret", hostKeys: server.hostKeyStore(), certificates: certs,
                                                approveHostKey: { _ in false }, approveCertificate: { _ in true })
        #expect(session.startDirectory == "/site")
        #expect(!session.canExec)
        // The transfer connection reuses the accepted certificate without asking.
        let transfer = await session.transferConnection()
        #expect(transfer !== session.client)
        #expect(try await transfer.list("/site").map(\.name) == ["index.html"])
        await session.close()
    }

    @Test func transfersUseASecondConnection() async throws {
        let session = try await connect()
        let transfer = await session.transferConnection()
        #expect(transfer !== session.client)
        #expect(await session.transferConnection() === transfer)
        await session.close()
        #expect(await !transfer.isConnected)
    }

    @Test func uploadAndDownloadThroughTheQueue() async throws {
        let session = try await connect()
        let dir = try server.scratch()
        let local = FileManager.default.temporaryDirectory.appending(path: "s-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local.appending(path: "folder"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: local.appending(path: "one.txt"))
        try Data("two".utf8).write(to: local.appending(path: "folder/two.txt"))
        let items = [local.appending(path: "one.txt"), local.appending(path: "folder")]

        #expect(try await session.conflicts(uploading: items, to: dir).isEmpty)
        try await session.upload(items, to: dir, overwrite: false)
        #expect(try await session.conflicts(uploading: items, to: dir).sorted() == ["folder", "one.txt"])
        await #expect(throws: RemoteError.alreadyExists(dir + "/one.txt")) {
            try await session.upload([items[0]], to: dir, overwrite: false)
        }
        try await session.upload(items, to: dir, overwrite: true)

        let back = FileManager.default.temporaryDirectory.appending(path: "s-back-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let files = try await session.client.list(dir)
        try await session.download(files, into: back)
        #expect(try String(contentsOf: back.appending(path: "folder/two.txt"), encoding: .utf8) == "two")
        try await session.download(files.first { $0.name == "one.txt" }!, to: back.appending(path: "renamed.txt"))
        #expect(try String(contentsOf: back.appending(path: "renamed.txt"), encoding: .utf8) == "one")
        await session.close()
    }

    // MARK: Browser

    @Test func navigationHistory() async throws {
        let dir = try server.scratch()
        for sub in ["a", "b"] { try FileManager.default.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true) }
        let session = try await connect(initialDirectory: dir)
        let browser = Browser(session: session)
        await browser.open(browser.path)
        #expect(browser.visible.map(\.name) == ["a", "b"])
        #expect(!browser.canGoBack)

        await browser.open(dir + "/a")
        await browser.open(dir + "/b")
        await browser.goBack()
        #expect(browser.path == dir + "/a")
        #expect(browser.canGoForward)
        await browser.goForward()
        #expect(browser.path == dir + "/b")
        await browser.goUp()
        #expect(browser.path == dir)
        #expect(!browser.canGoForward, "going somewhere new drops the forward history")

        await browser.open(dir + "/missing")
        #expect(browser.error != nil)
        #expect(browser.visible.isEmpty)
        await browser.goBack()
        #expect(browser.error == nil)
        await session.close()
    }

    @Test func filteringAndSorting() async throws {
        let dir = try server.scratch()
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/zeta", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/Alpha", withIntermediateDirectories: true)
        try Data(count: 300).write(to: URL(fileURLWithPath: dir + "/big.txt"))
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/small.txt"))
        try Data(count: 1).write(to: URL(fileURLWithPath: dir + "/file10.txt"))
        try Data(count: 1).write(to: URL(fileURLWithPath: dir + "/file9.txt"))
        try Data(count: 1).write(to: URL(fileURLWithPath: dir + "/.hidden"))

        let session = try await connect(initialDirectory: dir)
        let browser = Browser(session: session)
        await browser.refresh()
        #expect(browser.visible.map(\.name) == ["Alpha", "zeta", "big.txt", "file9.txt", "file10.txt", "small.txt"])

        browser.showHidden = true
        #expect(browser.visible.map(\.name).contains(".hidden"))
        browser.filter = "FILE"
        #expect(browser.visible.map(\.name) == ["file9.txt", "file10.txt"])
        browser.filter = ""
        browser.showHidden = false

        browser.sortKey = .size
        browser.ascending = false
        #expect(browser.visible.map(\.name) == ["Alpha", "zeta", "big.txt", "small.txt", "file9.txt", "file10.txt"])
        await session.close()
    }

    @Test func fileOperations() async throws {
        let dir = try server.scratch()
        let session = try await connect(initialDirectory: dir)
        let browser = Browser(session: session)
        await browser.refresh()
        func names() -> [String] { browser.visible.map(\.name) }
        func file(_ name: String) -> RemoteFile { browser.visible.first { $0.name == name }! }

        #expect(try await browser.createFolder(named: " docs ") == dir + "/docs")
        try await browser.createFile(named: "notes.txt")
        #expect(names() == ["docs", "notes.txt"])
        await #expect(throws: RemoteError.alreadyExists(dir + "/notes.txt")) { try await browser.createFile(named: "notes.txt") }
        await #expect(throws: RemoteError.self) { try await browser.createFile(named: "a/b") }

        try await browser.rename(file("notes.txt"), to: "readme.md")
        try await browser.setPermissions(file("readme.md"), to: 0o600)
        #expect(file("readme.md").permissionsString == "-rw-------")

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: date) }()
        try await browser.duplicate([file("readme.md"), file("docs")], date: date)
        #expect(Set(names()) == ["docs", "docs_\(stamp)", "readme.md", "readme_\(stamp).md"])

        try await browser.move([file("readme.md")], to: dir + "/docs")
        try await browser.copy([file("readme_\(stamp).md")], to: dir + "/docs")
        #expect(Set(try await session.client.list(dir + "/docs").map(\.name)) == ["readme.md", "readme_\(stamp).md"])
        await #expect(throws: RemoteError.alreadyExists(dir + "/docs/readme_\(stamp).md")) {
            try await browser.copy([file("readme_\(stamp).md")], to: dir + "/docs")
        }

        try await browser.delete([file("docs"), file("docs_\(stamp)"), file("readme_\(stamp).md")])
        #expect(names().isEmpty)
        await session.close()
    }
}

@Test func validNames() throws {
    #expect(try Browser.validName("  a.txt ") == "a.txt")
    for bad in ["", "  ", ".", "..", "a/b"] {
        #expect(throws: RemoteError.self) { try Browser.validName(bad) }
    }
}

@Test func parentsAndAncestors() {
    #expect(remoteParent("/var/www/site") == "/var/www")
    #expect(remoteParent("/var") == "/")
    #expect(remoteParent("/") == "/")
    #expect(remoteAncestors("/srv/www/duckburg") == ["/srv/www/duckburg", "/srv/www", "/srv", "/"])
    #expect(remoteAncestors("/") == ["/"])
}
