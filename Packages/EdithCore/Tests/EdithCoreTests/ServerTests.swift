// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

private struct LinuxConfig: Decodable {
    var servers: [Server]
    var folders: [Folder]
}

private func loadFixture() throws -> LinuxConfig {
    let url = try #require(Bundle.module.url(forResource: "servers-linux", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(LinuxConfig.self, from: Data(contentsOf: url))
}

@Test func decodesLinuxConfig() throws {
    let config = try loadFixture()
    #expect(config.servers.count == 2)

    let prod = config.servers[0]
    #expect(prod.displayName == "Production")
    #expect(prod.authMethod == .key)
    #expect(prod.keyFile == "/home/mk/.ssh/id_ed25519")
    #expect(prod.folderID == config.folders[0].id)
    #expect(config.folders[0].expanded == false)
}

@Test func missingKeysTakeDefaultsAndUnknownKeysAreIgnored() throws {
    let ftp = try loadFixture().servers[1]
    #expect(ftp.serverProtocol == .ftp)
    #expect(ftp.ftpEncryption == .explicitRequired)
    #expect(ftp.authMethod == .password)
    #expect(ftp.initialDirectory == "/")
    #expect(ftp.folderID == "")
    #expect(ftp.displayName == "web@ftp.example.org")
}

@Test func encodesWithLinuxKeys() throws {
    let server = Server(id: "x", host: "h", authMethod: .keyWithPassphrase)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as? [String: Any])
    #expect(json["auth_method"] as? String == "key+passphrase")
    #expect(json["protocol"] as? String == "sftp")
    #expect(Set(json.keys) == [
        "id", "name", "host", "port", "username", "key_file", "auth_method",
        "protocol", "ftp_encryption", "initial_directory", "folder_id",
    ])
}

@Test func legacyFTPSAndUnknownValuesDecode() throws {
    let json = #"""
    [{"protocol": "ftps", "auth_method": "kerberos"},
     {"protocol": "ftps", "ftp_encryption": "explicit_required"},
     {"protocol": "gopher"}]
    """#
    let servers = try JSONDecoder().decode([Server].self, from: Data(json.utf8))
    #expect(servers[0].serverProtocol == .ftp)
    #expect(servers[0].ftpEncryption == .implicit)
    #expect(servers[0].authMethod == .password)
    #expect(servers[1].ftpEncryption == .explicitRequired)
    #expect(servers[2].serverProtocol == .sftp)
}
