// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import Synchronization

public enum ConfigError: Error, LocalizedError {
    /// The file exists but isn't valid JSON. Writes are refused so a
    /// preference change can't replace a damaged file, and the server list in
    /// it, with a near-empty one.
    case unreadable(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            String(localized: "The settings file \(url.path) can't be read: \(error.localizedDescription)", bundle: .module)
        }
    }
}

/// A pinned file or folder on a server.
public struct Pin: Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// servers.json: servers, folders, recents, pins, pinned servers and
/// preferences, in the Linux app's format.
///
/// Every mutation is a read-modify-write of the whole file, under one lock so
/// windows can't interleave. Keys this version doesn't know are kept as they
/// are, so a file shared with the Linux app (or a newer version) loses nothing.
public final class ConfigStore: Sendable {
    public static let recentsMax = 5
    public static let backupsKept = 10

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Edith/servers.json")
    }

    public let fileURL: URL

    /// The last file contents read, keyed by modification date and size, so
    /// repeated reads don't hit the disk. The text is cached, not the parsed
    /// dictionary, so every caller gets its own copy to modify.
    private struct Cache {
        var modified: Date
        var size: Int
        var data: Data
    }
    private let cache = Mutex<Cache?>(nil)
    private static let log = Logger(subsystem: "de.singular.edith", category: "config")

    public init(fileURL: URL = ConfigStore.defaultURL) {
        self.fileURL = fileURL
    }

    // MARK: Raw access

    /// The whole file as a dictionary. A missing file is empty. A damaged
    /// file reads as empty too, but `mutate` refuses to write over it.
    func loadRaw() -> [String: Any] {
        cache.withLock { cache in (try? read(&cache)) ?? [:] }
    }

    private func read(_ cache: inout Cache?) throws -> [String: Any] {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            cache = nil
            return [:]
        }
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        let size = attrs[.size] as? Int ?? -1

        let data: Data
        if let c = cache, c.modified == modified, c.size == size {
            data = c.data
        } else {
            data = try Data(contentsOf: fileURL)
            cache = Cache(modified: modified, size: size, data: data)
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw ConfigError.unreadable(fileURL, underlying: error)
        }
    }

    /// Read, modify and write the file as one step.
    ///
    /// Only `deliberate` writes, whose job is the server list, may leave it
    /// empty. Anything else that would drop every server is skipped and
    /// logged instead: on Linux, a preference write once landed an empty
    /// dictionary on top of 218 servers.
    func mutate(deliberate: Bool = false, _ body: (inout [String: Any]) throws -> Void) throws {
        try cache.withLock { cache in
            let current = try read(&cache)
            var data = current
            try body(&data)

            let hadServers = !((current["servers"] as? [Any])?.isEmpty ?? true)
            let hasServers = !((data["servers"] as? [Any])?.isEmpty ?? true)
            if !deliberate && hadServers && !hasServers {
                Self.log.error("REFUSED config write that would drop \((current["servers"] as? [Any])?.count ?? 0) servers from \(self.fileURL.path, privacy: .public) (keys: \(data.keys.sorted(), privacy: .public))")
                return
            }

            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try json.write(to: fileURL, options: .atomic)
            cache = nil
        }
    }

    /// True when the file exists but doesn't parse. It reads as empty then,
    /// and every write is refused, so the app has to say why the server list
    /// is empty and changes don't stick.
    public var isDamaged: Bool {
        cache.withLock { cache in
            do { _ = try read(&cache); return false } catch { return true }
        }
    }

    public var backupsURL: URL {
        fileURL.deletingLastPathComponent().appending(path: "backups")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: Servers and folders

    public func servers() -> [Server] {
        decode([Server].self, loadRaw()["servers"]) ?? []
    }

    public func folders() -> [Folder] {
        decode([Folder].self, loadRaw()["folders"]) ?? []
    }

    /// Replaces both lists. The only writer allowed to empty the server list.
    public func saveAll(servers: [Server], folders: [Folder]) throws {
        try mutate(deliberate: true) { data in
            data["servers"] = try encode(servers)
            data["folders"] = try encode(folders)
        }
    }

    public func saveServers(_ servers: [Server]) throws {
        try saveAll(servers: servers, folders: folders())
    }

    public func saveFolders(_ folders: [Folder]) throws {
        try saveAll(servers: servers(), folders: folders)
    }

    public func addServer(_ server: Server) throws {
        try saveServers(servers() + [server])
    }

    public func updateServer(_ server: Server) throws {
        try saveServers(servers().map { $0.id == server.id ? server : $0 })
    }

    public func deleteServer(id: String) throws {
        try saveServers(servers().filter { $0.id != id })
    }

    public func moveServer(id: String, toFolder folderID: String) throws {
        try saveServers(servers().map { s in
            var s = s
            if s.id == id { s.folderID = folderID }
            return s
        })
    }

    public func addFolder(_ folder: Folder) throws {
        try saveFolders(folders() + [folder])
    }

    public func updateFolder(_ folder: Folder) throws {
        try saveFolders(folders().map { $0.id == folder.id ? folder : $0 })
    }

    public func deleteFolder(id: String) throws {
        try saveFolders(folders().filter { $0.id != id })
    }

    /// Puts folders in the given order. Folders missing from `ids` keep
    /// their place at the end rather than being dropped.
    public func reorderFolders(_ ids: [String]) throws {
        let all = folders()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = ids.compactMap { byID[$0] }
        let rest = all.filter { !ids.contains($0.id) }
        try saveFolders(ordered + rest)
    }

    // MARK: Recents

    public func recents(serverID: String) -> [String] {
        (loadRaw()["recents"] as? [String: [String]])?[serverID] ?? []
    }

    /// Moves `path` to the front of the server's recents, keeping five.
    public func pushRecent(serverID: String, path: String) throws {
        try mutate { data in
            var recents = data["recents"] as? [String: [String]] ?? [:]
            let paths = [path] + (recents[serverID] ?? []).filter { $0 != path }
            recents[serverID] = Array(paths.prefix(Self.recentsMax))
            data["recents"] = recents
        }
    }

    public func deleteRecent(serverID: String, path: String) throws {
        try mutate { data in
            var recents = data["recents"] as? [String: [String]] ?? [:]
            recents[serverID] = (recents[serverID] ?? []).filter { $0 != path }
            data["recents"] = recents
        }
    }

    // MARK: Pins

    public func pins(serverID: String) -> [Pin] {
        let entries = (loadRaw()["pins"] as? [String: [[String: Any]]])?[serverID] ?? []
        return entries.compactMap { e in
            (e["path"] as? String).map { Pin(path: $0, isDirectory: e["is_dir"] as? Bool ?? false) }
        }
    }

    public func addPin(serverID: String, _ pin: Pin) throws {
        try mutate { data in
            var pins = data["pins"] as? [String: [[String: Any]]] ?? [:]
            var entries = pins[serverID] ?? []
            if !entries.contains(where: { $0["path"] as? String == pin.path }) {
                entries.append(["path": pin.path, "is_dir": pin.isDirectory])
            }
            pins[serverID] = entries
            data["pins"] = pins
        }
    }

    public func deletePin(serverID: String, path: String) throws {
        try mutate { data in
            var pins = data["pins"] as? [String: [[String: Any]]] ?? [:]
            pins[serverID] = (pins[serverID] ?? []).filter { $0["path"] as? String != path }
            data["pins"] = pins
        }
    }

    // MARK: Pinned servers

    public func pinnedServers() -> [String] {
        loadRaw()["pinned_servers"] as? [String] ?? []
    }

    public func isServerPinned(_ id: String) -> Bool {
        pinnedServers().contains(id)
    }

    public func toggleServerPin(_ id: String) throws {
        try mutate { data in
            var pinned = data["pinned_servers"] as? [String] ?? []
            if let i = pinned.firstIndex(of: id) {
                pinned.remove(at: i)
            } else {
                pinned.append(id)
            }
            data["pinned_servers"] = pinned
        }
    }

    // MARK: Preferences

    /// A preference by its Linux key (`editor_font_size`, …), or nil if it
    /// is unset or has another type.
    public func preference<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        decode(T.self, (loadRaw()["preferences"] as? [String: Any])?[key])
    }

    public func setPreference(_ key: String, _ value: some Encodable) throws {
        try mutate { data in
            var prefs = data["preferences"] as? [String: Any] ?? [:]
            prefs[key] = try encode(value)
            data["preferences"] = prefs
        }
    }

    /// A preference as JSON text, for values with no fixed shape, like
    /// the Monaco overrides object.
    public func preferenceJSON(_ key: String) -> String? {
        guard let value = (loadRaw()["preferences"] as? [String: Any])?[key],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores JSON text as a preference value. Throws if it isn't valid JSON.
    public func setPreferenceJSON(_ key: String, _ json: String) throws {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        try mutate { data in
            var prefs = data["preferences"] as? [String: Any] ?? [:]
            prefs[key] = value
            data["preferences"] = prefs
        }
    }

    // MARK: Backups

    /// Copies the file into backups/ beside it, keeping the last ten.
    ///
    /// Called once at startup. Skips a file with no servers, and one that is
    /// identical to the newest backup, so idle launches don't rotate real
    /// history out. Never throws: a failed backup must not stop the app.
    public func backupNow(date: Date = .now) {
        do {
            guard exists, !servers().isEmpty else { return }
            let content = try Data(contentsOf: fileURL)

            let dir = fileURL.deletingLastPathComponent().appending(path: "backups")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            func existing() throws -> [URL] {
                try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("servers-") && $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            if let newest = try existing().last, try Data(contentsOf: newest) == content {
                return
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try content.write(to: dir.appending(path: "servers-\(formatter.string(from: date)).json"))

            for stale in try existing().dropLast(Self.backupsKept) {
                try FileManager.default.removeItem(at: stale)
            }
        } catch {
            Self.log.error("backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - JSON bridging

/// Codable value → JSONSerialization object, so typed values can live in the
/// untyped dictionary that preserves unknown keys.
private func encode(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
}

private func decode<T: Decodable>(_ type: T.Type, _ object: Any?) -> T? {
    guard let object,
          let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
    else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
