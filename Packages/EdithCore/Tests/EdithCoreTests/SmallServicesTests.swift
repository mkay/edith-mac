// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

@Test func keychainRoundTrip() throws {
    // A service of its own, so the test never touches real Edith items.
    let keychain = Keychain(service: "de.singular.edith.tests.\(UUID().uuidString)")
    defer { try? keychain.deleteSecret(for: "server") }

    #expect(try keychain.secret(for: "server") == nil)
    try keychain.setSecret("first", for: "server")
    #expect(try keychain.secret(for: "server") == "first")
    try keychain.setSecret("second ✓", for: "server")
    #expect(try keychain.secret(for: "server") == "second ✓")
    try keychain.deleteSecret(for: "server")
    #expect(try keychain.secret(for: "server") == nil)
    try keychain.deleteSecret(for: "server")
}

@Test func tempFilesKeepNamesApartAndCleanUp() throws {
    let parent = FileManager.default.temporaryDirectory.appending(path: "tf-\(UUID().uuidString)")
    let temp = TempFiles(parent: parent)
    let a = try temp.path(for: "/var/www/index.php")
    let b = try temp.path(for: "/srv/other/index.php")
    #expect(a.lastPathComponent == "index.php")
    #expect(a != b)
    #expect(a.deletingLastPathComponent().deletingLastPathComponent() == b.deletingLastPathComponent().deletingLastPathComponent())

    try Data("x".utf8).write(to: a)
    temp.cleanup()
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(try temp.path(for: "/again.txt").lastPathComponent == "again.txt")
    temp.cleanup()
    try? FileManager.default.removeItem(at: parent)
}

@Test func permissionsString() {
    #expect(RemoteFile(name: "d", path: "/d", mode: 0o040755).permissionsString == "drwxr-xr-x")
    #expect(RemoteFile(name: "f", path: "/f", mode: 0o100644).permissionsString == "-rw-r--r--")
    #expect(RemoteFile(name: "l", path: "/l", mode: 0o120777).permissionsString == "lrwxrwxrwx")
    #expect(RemoteFile(name: "s", path: "/s", mode: 0o104755).permissionsString == "-rwsr-xr-x")
    #expect(RemoteFile(name: "t", path: "/t", mode: 0o041777).permissionsString == "drwxrwxrwt")
    #expect(RemoteFile(name: "u", path: "/u", mode: 0o102640).permissionsString == "-rw-r-S---")
    #expect(RemoteFile(name: "x", path: "/x").permissionsString == "----------")
    #expect(RemoteFile(name: "f", path: "/f", mode: 0o100644).permissions == 0o644)
}

@Test func remotePathHelpers() {
    #expect(remoteJoin("/", "a") == "/a")
    #expect(remoteJoin("/var/www", "a") == "/var/www/a")
    #expect(remoteJoin("/var/www/", "a") == "/var/www/a")
    #expect(remoteName("/var/www/index.php") == "index.php")
    #expect(remoteName("/var/www/") == "www")
}

@Test func sshKeyTypeFromBlob() {
    var blob = Data([0, 0, 0, 11])
    blob.append(Data("ssh-ed25519".utf8))
    blob.append(Data([0, 0, 0, 32] + Array(repeating: 1, count: 32)))
    #expect(sshStringPrefix(blob) == "ssh-ed25519")
    #expect(sshStringPrefix(Data([0, 0, 1])) == nil)
    #expect(sshStringPrefix(Data([0, 0, 0, 9, 65])) == nil)
}
