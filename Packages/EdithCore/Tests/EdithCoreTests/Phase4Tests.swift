// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "p4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

// MARK: - File watcher

@Test func watcherSeesInPlaceAndAtomicSaves() async throws {
    let dir = try tempDir()
    let file = dir.appending(path: "page.php")
    try Data("one".utf8).write(to: file)
    let count = Counter()
    let watcher = try #require(FileWatcher(url: file, debounce: .milliseconds(100)) { count.bump() })

    try Data("two".utf8).write(to: file)                   // in place
    try await Task.sleep(for: .milliseconds(400))
    #expect(count.value == 1)

    try Data("three!".utf8).write(to: file, options: .atomic)  // temp file + rename
    try await Task.sleep(for: .milliseconds(400))
    #expect(count.value == 2)

    try Data("x".utf8).write(to: dir.appending(path: "other.txt"))  // a neighbour
    try await Task.sleep(for: .milliseconds(400))
    #expect(count.value == 2, "other files in the folder don't count")
    watcher.cancel()
}

// MARK: - Archives

@Test func archiveNames() {
    #expect(ArchiveFormat.normalized("site").name == "site.zip")
    #expect(ArchiveFormat.normalized("site.TGZ").format == .tarGz)
    #expect(ArchiveFormat.normalized("a.tar.xz").format == .tarXz)
    #expect(shellQuote("it's here") == "'it'\\''s here'")
}

@MainActor
@Test(.enabled(if: LocalSSHServer.shared != nil)) func archiveOnTheServer() async throws {
    let ssh = LocalSSHServer.shared!
    let dir = try ssh.scratch()
    try FileManager.default.createDirectory(atPath: dir + "/my site", withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: URL(fileURLWithPath: dir + "/my site/index.html"))
    let session = try await Session.connect(to: ssh.server(initialDirectory: dir), secret: nil,
                                            hostKeys: ssh.hostKeyStore(), approveHostKey: { _ in false })
    #expect(session.canExec)
    let folder = try await session.client.stat(dir + "/my site")
    #expect(try await session.createArchive(of: folder, named: "backup.tar.gz") == dir + "/backup.tar.gz")
    #expect(try listTar(dir + "/backup.tar.gz").contains("my site/index.html"))
    await #expect(throws: RemoteError.alreadyExists(dir + "/backup.tar.gz")) {
        try await session.createArchive(of: folder, named: "backup.tar.gz")
    }
    await session.close()
}

@MainActor
@Test(.enabled(if: LocalFTPServer.available)) func archiveOverFTPIsPackedLocally() async throws {
    let ftp = try LocalFTPServer()
    try ftp.write("a", to: "/site/a.txt")
    try ftp.write("b", to: "/site/sub/b.txt")
    let server = Server(host: "127.0.0.1", port: ftp.port, username: "test", serverProtocol: .ftp, initialDirectory: "/")
    let session = try await Session.connect(to: server, secret: "secret", hostKeys: HostKeyStore(), approveHostKey: { _ in false })
    let folder = try await session.client.stat("/site")
    #expect(try await session.createArchive(of: folder, named: "site") == "/site.zip")
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-l", ftp.root + "/site.zip"]
    let out = Pipe()
    unzip.standardOutput = out
    try unzip.run()
    let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(listing.contains("site/sub/b.txt") && listing.contains("site/a.txt"))
    await session.close()
}

private func listTar(_ path: String) throws -> String {
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-tzf", path]
    let out = Pipe()
    tar.standardOutput = out
    try tar.run()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

// MARK: - FileZilla and export

@Test func fileZillaSiteManager() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FileZilla3 version="3.66.0">
      <Servers>
        <Server>
          <Host>example.com</Host><Port>22</Port><Protocol>1</Protocol><Type>0</Type>
          <User>deploy</User><Logontype>5</Logontype><Keyfile>/Users/me/.ssh/id_ed25519</Keyfile>
          <Name>Prod</Name><RemoteDir>1 0 3 var 3 www</RemoteDir>
        </Server>
        <Folder expanded="1">Clients
          <Server>
            <Host>ftp.example.org</Host><Port>21</Port><Protocol>4</Protocol>
            <User>web</User><Logontype>1</Logontype><Pass encoding="base64">aHVudGVyMg==</Pass>
            <Name>Shop</Name><RemoteDir>1 0 9 my folder 4 html</RemoteDir>
          </Server>
          <Server>
            <Host>legacy.example.net</Host><Protocol>6</Protocol><User>u</User>
            <Logontype>1</Logontype><Pass encoding="crypt">opaque</Pass><Name>Old</Name>
          </Server>
        </Folder>
      </Servers>
    </FileZilla3>
    """
    let url = try tempDir().appending(path: "sitemanager.xml")
    try xml.write(to: url, atomically: true, encoding: .utf8)
    let file = try ServerFile.read(url)

    #expect(file.servers.map(\.name) == ["Prod", "Shop", "Old"])
    let prod = file.servers[0], shop = file.servers[1], old = file.servers[2]
    #expect(prod.serverProtocol == .sftp && prod.authMethod == .key && prod.keyFile == "/Users/me/.ssh/id_ed25519")
    #expect(prod.initialDirectory == "/var/www")
    #expect(shop.ftpEncryption == .explicitRequired && shop.initialDirectory == "/my folder/html")
    #expect(old.ftpEncryption == .none && old.port == 21)
    #expect(file.folders.map(\.name) == ["Clients"] && shop.folderID == file.folders[0].id)
    #expect(file.passwords == [shop.id: "hunter2"], "master-password ones can't be read")
}

@Test func remoteDirDecoding() {
    #expect(FileZillaImport.decodeRemoteDir("1 0 4 home 3 foo") == "/home/foo")
    #expect(FileZillaImport.decodeRemoteDir("1 0") == "/")
    #expect(FileZillaImport.decodeRemoteDir("") == "/")
    #expect(FileZillaImport.decodeRemoteDir("8 2 C: 5 Users") == "/Users")
}

@Test func exportRoundTrip() throws {
    let servers = [Server(id: "a", name: "A", host: "h"), Server(id: "b", host: "i", folderID: "g")]
    let folders = [Folder(id: "g", name: "G")]
    let blob = try SecretsBlob.encrypt(["a": "pw"], passphrase: "p")
    let url = try tempDir().appending(path: ConfigStore.defaultExportName())
    try ConfigStore.writeExport(try ConfigStore.exportData(servers: servers, folders: folders, secrets: blob), to: url, hasSecrets: true)

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attrs[.posixPermissions] as? Int == 0o600)
    let back = try ServerFile.read(url)
    #expect(back.servers == servers && back.folders == folders)
    #expect(try back.secrets?.decrypt(passphrase: "p") == ["a": "pw"])
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(raw["edith_export"] as? Int == 1)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"pw\""))
}
