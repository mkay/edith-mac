// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

private func tempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func emptyStore() throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory.appending(path: "import-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ConfigStore(fileURL: dir.appending(path: "servers.json"))
}

@Test func parsesLinuxServersFile() throws {
    let url = try #require(Bundle.module.url(forResource: "servers-linux", withExtension: "json", subdirectory: "Fixtures"))
    let file = try ConfigStore.parseServerFile(url)
    #expect(file.servers.count == 2)
    #expect(file.folders.count == 1)
    #expect(file.secrets == nil)
}

@Test func rejectsWhatIsntAServerList() throws {
    #expect(throws: ServerImportError.self) { try ConfigStore.parseServerFile(try tempFile("<xml/>")) }
    #expect(throws: ServerImportError.self) { try ConfigStore.parseServerFile(try tempFile(#"{"preferences": {}}"#)) }
    #expect(throws: ServerImportError.self) { try ConfigStore.parseServerFile(try tempFile(#"{"servers": 3}"#)) }
}

@Test func mergeMatchesOnIDAndParksOrphans() throws {
    let store = try emptyStore()
    let group = Folder(id: "g", name: "G")
    try store.saveAll(servers: [Server(id: "a", name: "A")], folders: [group])

    let result = try store.importServers(
        [Server(id: "a", name: "A2", folderID: "g"), Server(id: "b", name: "B", folderID: "nowhere")],
        folders: [group, Folder(id: "h", name: "H")]
    )
    #expect(result == ImportResult(added: 1, updated: 1, foldersAdded: 1))
    #expect(store.servers().map(\.name) == ["A2", "B"])
    #expect(store.servers().map(\.folderID) == ["g", ""])
    #expect(store.folders().map(\.id) == ["g", "h"])

    let again = try store.importServers([Server(id: "b", name: "B")], folders: [])
    #expect(again == ImportResult(added: 0, updated: 1, foldersAdded: 0))
}

@Test func replaceSwapsEverything() throws {
    let store = try emptyStore()
    try store.saveAll(servers: [Server(id: "a")], folders: [Folder(id: "g")])
    let result = try store.importServers([Server(id: "z")], folders: [], replace: true)
    #expect(result == ImportResult(added: 1, updated: 0, foldersAdded: 0))
    #expect(store.servers().map(\.id) == ["z"])
    #expect(store.folders().isEmpty)
}
