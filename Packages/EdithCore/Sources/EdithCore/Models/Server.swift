// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A saved server connection, stored in servers.json.
///
/// The JSON shape is the Linux app's `ServerInfo` dataclass, byte for byte, so
/// configs and exports move between the two apps unchanged. Decoding follows
/// the Python `from_dict`: unknown keys are ignored and missing keys take their
/// defaults, so a config written by a newer version still loads.
public struct Server: Codable, Hashable, Identifiable, Sendable {
    public enum AuthMethod: String, Codable, Sendable {
        case password
        case key
        case keyWithPassphrase = "key+passphrase"
    }

    public enum ServerProtocol: String, Codable, Sendable {
        case sftp
        case ftp
    }

    public enum FTPEncryption: String, Codable, Sendable {
        case none
        case explicitOptional = "explicit_optional"
        case explicitRequired = "explicit_required"
        case implicit
    }

    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var keyFile: String
    public var authMethod: AuthMethod
    public var serverProtocol: ServerProtocol
    public var ftpEncryption: FTPEncryption
    public var initialDirectory: String
    /// Empty means ungrouped.
    public var folderID: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        keyFile: String = "",
        authMethod: AuthMethod = .password,
        serverProtocol: ServerProtocol = .sftp,
        ftpEncryption: FTPEncryption = .none,
        initialDirectory: String = "/",
        folderID: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.keyFile = keyFile
        self.authMethod = authMethod
        self.serverProtocol = serverProtocol
        self.ftpEncryption = ftpEncryption
        self.initialDirectory = initialDirectory
        self.folderID = folderID
    }

    public var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username
        case keyFile = "key_file"
        case authMethod = "auth_method"
        case serverProtocol = "protocol"
        case ftpEncryption = "ftp_encryption"
        case initialDirectory = "initial_directory"
        case folderID = "folder_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Server(id: "")
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.id = id.isEmpty ? UUID().uuidString.lowercased() : id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? defaults.keyFile
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? defaults.authMethod
        serverProtocol = try c.decodeIfPresent(ServerProtocol.self, forKey: .serverProtocol) ?? defaults.serverProtocol
        ftpEncryption = try c.decodeIfPresent(FTPEncryption.self, forKey: .ftpEncryption) ?? defaults.ftpEncryption
        initialDirectory = try c.decodeIfPresent(String.self, forKey: .initialDirectory) ?? defaults.initialDirectory
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID) ?? defaults.folderID
    }
}

/// A group in the server list.
public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var expanded: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String = "New Group", expanded: Bool = true) {
        self.id = id
        self.name = name
        self.expanded = expanded
    }

    enum CodingKeys: String, CodingKey {
        case id, name, expanded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.id = id.isEmpty ? UUID().uuidString.lowercased() : id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Group"
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
    }
}
