// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ServerFile {
    /// Reads an Edith export, a plain servers.json, or a FileZilla
    /// sitemanager.xml, telling them apart by content.
    public static func read(_ url: URL) throws -> ServerFile {
        let head = try Data(contentsOf: url).prefix(512)
        let first = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).first
        switch first {
        case "<": return try FileZillaImport.parse(url)
        case "{": return try ConfigStore.parseServerFile(url)
        default: throw ServerImportError.unrecognized
        }
    }
}

/// FileZilla's Site Manager export (sitemanager.xml).
enum FileZillaImport {
    /// FileZilla's <Protocol> numbers.
    private static let protocols: [String: (Server.ServerProtocol, Server.FTPEncryption)] = [
        "0": (.ftp, .explicitOptional),  // "Use explicit FTP over TLS if available"
        "1": (.sftp, .none),
        "3": (.ftp, .implicit),
        "4": (.ftp, .explicitRequired),
        "6": (.ftp, .none),              // "Only use plain FTP"
    ]

    static func parse(_ url: URL) throws -> ServerFile {
        let document = try XMLDocument(contentsOf: url)
        guard let servers = try document.nodes(forXPath: "/FileZilla3/Servers").first as? XMLElement else {
            throw ServerImportError.noServerList
        }
        var file = ServerFile(servers: [], folders: [], secrets: nil)
        parse(container: servers, folderID: "", into: &file)
        return file
    }

    private static func parse(container: XMLElement, folderID: String, into file: inout ServerFile) {
        for child in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "Server":
                var server = parseServer(child)
                server.folderID = folderID
                file.servers.append(server)
                // Stored as base64 unless a master password protects it.
                if let pass = child.elements(forName: "Pass").first,
                   pass.attribute(forName: "encoding")?.stringValue == "base64",
                   let data = Data(base64Encoded: pass.stringValue ?? ""),
                   let password = String(data: data, encoding: .utf8), !password.isEmpty {
                    file.passwords[server.id] = password
                }
            case "Folder":
                // The name is the folder's own text, before its children.
                let name = child.children?.first { $0.kind == .text }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Folder"
                let folder = Folder(name: name.isEmpty ? "Folder" : name)
                file.folders.append(folder)
                parse(container: child, folderID: folder.id, into: &file)
            default:
                break
            }
        }
    }

    private static func parseServer(_ e: XMLElement) -> Server {
        func text(_ name: String) -> String { e.elements(forName: name).first?.stringValue ?? "" }
        let (proto, encryption) = protocols[text("Protocol")] ?? (.ftp, .explicitOptional)
        let keyFile = text("Keyfile")
        return Server(
            name: text("Name"),
            host: text("Host"),
            port: Int(text("Port")) ?? (proto == .sftp ? 22 : encryption == .implicit ? 990 : 21),
            username: text("User"),
            keyFile: keyFile,
            // Logontype 5 is "Key file".
            authMethod: proto == .sftp && text("Logontype") == "5" ? .key : .password,
            serverProtocol: proto,
            ftpEncryption: encryption,
            initialDirectory: decodeRemoteDir(text("RemoteDir"))
        )
    }

    /// FileZilla writes paths as `type prefixLength [prefix] (length segment)…`,
    /// e.g. `1 0 3 var 3 www` for /var/www. Lengths count characters, so
    /// segments may contain spaces.
    static func decodeRemoteDir(_ raw: String) -> String {
        let head = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard head.count >= 2, let prefixLength = Int(head[1]) else { return "/" }
        var rest = head.count == 3 ? Substring(head[2]) : ""
        if prefixLength > 0 {
            // A drive or volume (DOS, VMS) has no place in a Unix path.
            rest = rest.dropFirst(prefixLength).drop { $0 == " " }
        }
        var segments: [String] = []
        while !rest.isEmpty {
            let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let length = Int(fields[0]), fields[1].count >= length else { break }
            segments.append(String(fields[1].prefix(length)))
            rest = fields[1].dropFirst(length).drop { $0 == " " }
        }
        return "/" + segments.joined(separator: "/")
    }
}

extension ConfigStore {
    /// An export file in the Linux app's format. `secrets` is already
    /// encrypted: there's no way to write passwords in plain text.
    public static func exportData(servers: [Server], folders: [Folder], secrets: SecretsBlob?, date: Date = .now) throws -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var object: [String: Any] = [
            "edith_export": 1,
            "exported": formatter.string(from: date),
            "servers": try JSONSerialization.jsonObject(with: JSONEncoder().encode(servers)),
            "folders": try JSONSerialization.jsonObject(with: JSONEncoder().encode(folders)),
        ]
        if let secrets {
            object["secrets"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(secrets))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes an export; one carrying passwords is readable only by you.
    public static func writeExport(_ data: Data, to url: URL, hasSecrets: Bool) throws {
        try data.write(to: url, options: .atomic)
        if hasSecrets { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    public static func defaultExportName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return "edith-servers-\(formatter.string(from: date)).json"
    }
}
