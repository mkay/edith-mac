// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ImportResult: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var foldersAdded = 0

    public init(added: Int = 0, updated: Int = 0, foldersAdded: Int = 0) {
        self.added = added
        self.updated = updated
        self.foldersAdded = foldersAdded
    }
}

public struct ServerFile: Sendable {
    public var servers: [Server]
    public var folders: [Folder]
    /// An Edith export's encrypted passwords.
    public var secrets: SecretsBlob?
    /// Plain passwords by server id, from a FileZilla file.
    public var passwords: [String: String] = [:]
}

public enum ServerImportError: Error, LocalizedError {
    case notJSON(String)
    case noServerList
    case malformed
    case unrecognized

    public var errorDescription: String? {
        switch self {
        case .notJSON(let detail): "This file is not valid JSON: \(detail)"
        case .noServerList: "This file does not contain an Edith server list."
        case .malformed: "This file's server list is malformed."
        case .unrecognized: "Unrecognised file format: expected an Edith export, a servers.json or a FileZilla sitemanager.xml."
        }
    }
}

extension ConfigStore {
    /// Servers and folders from an Edith export or a plain servers.json
    /// (a backup, or the Linux app's own file), plus the export's encrypted
    /// passwords if it has any.
    public static func parseServerFile(_ url: URL) throws -> ServerFile {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .propertyListReadCorrupt {
            throw ServerImportError.notJSON(error.localizedDescription)
        }
        guard let dict = object as? [String: Any], let rawServers = dict["servers"] else { throw ServerImportError.noServerList }
        guard let servers = rawServers as? [[String: Any]], (dict["folders"] ?? []) is [[String: Any]] else {
            throw ServerImportError.malformed
        }
        let decode = { (value: Any) in try JSONSerialization.data(withJSONObject: value) }
        // A secrets block that doesn't parse is reported when it's decrypted,
        // not here: the servers are still worth importing.
        let secrets = (dict["secrets"] as? [String: Any]).flatMap { try? JSONDecoder().decode(SecretsBlob.self, from: decode($0)) }
        return ServerFile(
            servers: try JSONDecoder().decode([Server].self, from: decode(servers)),
            folders: try JSONDecoder().decode([Folder].self, from: decode(dict["folders"] ?? [])),
            secrets: secrets
        )
    }

    /// Merges servers and folders in, or replaces everything.
    ///
    /// Merging matches on id, so importing the same file again updates
    /// entries instead of duplicating them, and each server keeps the id its
    /// Keychain password is stored under. A server whose group exists
    /// neither in the file nor here is moved to ungrouped, not hidden.
    @discardableResult
    public func importServers(_ servers: [Server], folders: [Folder], replace: Bool = false) throws -> ImportResult {
        var result = ImportResult()
        var finalServers: [Server]
        var finalFolders: [Folder]
        if replace {
            (finalServers, finalFolders) = (servers, folders)
            result.added = servers.count
            result.foldersAdded = folders.count
        } else {
            finalFolders = self.folders()
            for folder in folders where !finalFolders.contains(where: { $0.id == folder.id }) {
                finalFolders.append(folder)
                result.foldersAdded += 1
            }
            finalServers = self.servers()
            for server in servers {
                if let i = finalServers.firstIndex(where: { $0.id == server.id }) {
                    finalServers[i] = server
                    result.updated += 1
                } else {
                    finalServers.append(server)
                    result.added += 1
                }
            }
        }
        let valid = Set(finalFolders.map(\.id))
        for i in finalServers.indices where !finalServers[i].folderID.isEmpty && !valid.contains(finalServers[i].folderID) {
            finalServers[i].folderID = ""
        }
        try saveAll(servers: finalServers, folders: finalFolders)
        return result
    }
}
