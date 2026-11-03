// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

/// A ConfigStore on a fresh file in its own temp directory.
private func makeStore(contents: String? = nil) throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory.appending(path: "config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "servers.json")
    if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
    return ConfigStore(fileURL: url)
}

private func fixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "servers-linux", withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func readsLinuxFileAndKeepsUnknownKeys() throws {
    let store = try makeStore(contents: try fixture())
    #expect(store.servers().count == 2)
    #expect(store.folders().first?.name == "Clients")
    #expect(store.preference("editor_font_size", as: Int.self) == 14)

    try store.setPreference("editor_minimap", true)
    let raw = store.loadRaw()
    // Fields this version doesn't model survive a rewrite.
    let servers = try #require(raw["servers"] as? [[String: Any]])
    #expect(servers.count == 2)
    #expect(store.preference("editor_font_size", as: Int.self) == 14)
    #expect(store.preference("editor_minimap", as: Bool.self) == true)
}

@Test func refusesNonDeliberateWriteThatDropsAllServers() throws {
    let store = try makeStore(contents: try fixture())
    try store.mutate { data in
        data["servers"] = []
        data["preferences"] = ["x": 1]
    }
    #expect(store.servers().count == 2, "a preference write must not empty the server list")
    #expect(store.preference("x", as: Int.self) == nil, "the refused write is skipped entirely")

    // Deleting the last server is a deliberate write and goes through.
    try store.saveServers([])
    #expect(store.servers().isEmpty)
}

@Test func refusesToOverwriteDamagedFile() throws {
    let store = try makeStore(contents: "{ not json")
    #expect(store.servers().isEmpty)
    #expect(throws: ConfigError.self) { try store.setPreference("x", 1) }
    #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ not json")
}

@Test func serverAndFolderOperations() throws {
    let store = try makeStore()
    #expect(!store.exists)
    let a = Server(name: "A", host: "a")
    let b = Server(name: "B", host: "b")
    try store.addServer(a)
    try store.addServer(b)
    #expect(store.exists)

    var renamed = a
    renamed.name = "A2"
    try store.updateServer(renamed)
    #expect(store.servers().map(\.name) == ["A2", "B"])

    let f1 = Folder(name: "One"), f2 = Folder(name: "Two"), f3 = Folder(name: "Three")
    for f in [f1, f2, f3] { try store.addFolder(f) }
    try store.moveServer(id: b.id, toFolder: f2.id)
    #expect(store.servers().first { $0.id == b.id }?.folderID == f2.id)

    try store.reorderFolders([f3.id, f1.id])
    #expect(store.folders().map(\.name) == ["Three", "One", "Two"])

    try store.deleteFolder(id: f1.id)
    try store.deleteServer(id: a.id)
    #expect(store.folders().map(\.name) == ["Three", "Two"])
    #expect(store.servers().map(\.name) == ["B"])
}

@Test func recentsKeepFiveMostRecentFirst() throws {
    let store = try makeStore()
    for i in 1...7 { try store.pushRecent(serverID: "s", path: "/p\(i)") }
    try store.pushRecent(serverID: "s", path: "/p4")
    #expect(store.recents(serverID: "s") == ["/p4", "/p7", "/p6", "/p5", "/p3"])
    try store.deleteRecent(serverID: "s", path: "/p6")
    #expect(store.recents(serverID: "s") == ["/p4", "/p7", "/p5", "/p3"])
    #expect(store.recents(serverID: "other").isEmpty)
}

@Test func pinsAndPinnedServers() throws {
    let store = try makeStore()
    try store.addPin(serverID: "s", Pin(path: "/var/www", isDirectory: true))
    try store.addPin(serverID: "s", Pin(path: "/var/www", isDirectory: true))
    try store.addPin(serverID: "s", Pin(path: "/etc/hosts", isDirectory: false))
    #expect(store.pins(serverID: "s") == [Pin(path: "/var/www", isDirectory: true), Pin(path: "/etc/hosts", isDirectory: false)])
    try store.deletePin(serverID: "s", path: "/var/www")
    #expect(store.pins(serverID: "s").map(\.path) == ["/etc/hosts"])

    // The Linux key names, so pins survive the trip between apps.
    let raw = try #require((store.loadRaw()["pins"] as? [String: [[String: Any]]])?["s"]?.first)
    #expect(raw["is_dir"] as? Bool == false)

    try store.toggleServerPin("s")
    #expect(store.isServerPinned("s"))
    try store.toggleServerPin("s")
    #expect(!store.isServerPinned("s"))
}

@Test func backupsRotateAndSkipUnchanged() throws {
    let store = try makeStore(contents: try fixture())
    let backups = store.fileURL.deletingLastPathComponent().appending(path: "backups")
    func count() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: backups.path).count) ?? 0 }

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    store.backupNow(date: start)
    store.backupNow(date: start + 1)
    #expect(count() == 1, "an unchanged file isn't backed up twice")

    for i in 0..<12 {
        try store.setPreference("n", i)
        store.backupNow(date: start + 10 + Double(i))
    }
    #expect(count() == ConfigStore.backupsKept)
}

@Test func noBackupWithoutServers() throws {
    let store = try makeStore(contents: #"{"servers": [], "preferences": {"a": 1}}"#)
    store.backupNow()
    let backups = store.fileURL.deletingLastPathComponent().appending(path: "backups")
    #expect(!FileManager.default.fileExists(atPath: backups.path))
}

@Test func rawJSONPreferences() throws {
    let store = try makeStore()
    #expect(store.preferenceJSON("editor_overrides") == nil)
    try store.setPreferenceJSON("editor_overrides", #"{"cursorStyle": "block", "html": {"format": {"wrapLineLength": 0}}}"#)
    let back = try #require(store.preferenceJSON("editor_overrides"))
    let parsed = try #require(JSONSerialization.jsonObject(with: Data(back.utf8)) as? [String: Any])
    #expect(parsed["cursorStyle"] as? String == "block")
    #expect(throws: (any Error).self) { try store.setPreferenceJSON("x", "{oops") }
}
