// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

@Test func codecKeepsEncodings() throws {
    let utf8 = try #require(TextCodec.decode(Data("grüß\n".utf8)))
    #expect(utf8.text == "grüß\n" && utf8.encoding == .utf8 && !utf8.bom)

    let bom = try #require(TextCodec.decode(Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)))
    #expect(bom.text == "x" && bom.bom)
    #expect(try TextCodec.encode("x", as: .utf8, bom: true, name: "f") == Data([0xEF, 0xBB, 0xBF, 0x78]))

    // "grüß" in Latin-1: not UTF-8, comes back byte for byte.
    let latin1 = Data([0x67, 0x72, 0xFC, 0xDF, 0x0A])
    let decoded = try #require(TextCodec.decode(latin1))
    #expect(decoded.text == "grüß\n" && decoded.encoding == .latin1)
    #expect(try TextCodec.encode(decoded.text, as: .latin1, bom: false, name: "f") == latin1)
    #expect(throws: WorkspaceError.cantEncode("f", .latin1)) { try TextCodec.encode("€ ✓", as: .latin1, bom: false, name: "f") }

    #expect(TextCodec.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01])) == nil, "NUL bytes mean binary")
    #expect(TextCodec.decode(Data())?.text == "")
}

@MainActor
@Suite(.serialized, .enabled(if: LocalSSHServer.shared != nil, "needs /usr/sbin/sshd"))
struct WorkspaceTests {
    let server = LocalSSHServer.shared!

    /// A workspace on a fresh scratch directory, with its own temp files.
    func make() async throws -> (Workspace, String) {
        let dir = try server.scratch()
        let session = try await Session.connect(to: server.server(initialDirectory: dir), secret: nil,
                                                hostKeys: server.hostKeyStore(), approveHostKey: { _ in false })
        let temp = TempFiles(parent: FileManager.default.temporaryDirectory.appending(path: "ws-\(UUID().uuidString)"))
        return (Workspace(session: session, tempFiles: temp), dir)
    }

    func write(_ text: String, to path: String, mtimeOffset: TimeInterval = 0) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        // SFTP mtimes have one-second resolution; push it clearly forward.
        if mtimeOffset != 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(mtimeOffset)], ofItemAtPath: path)
        }
    }

    @Test func openSelectsAndSavesBack() async throws {
        let (ws, dir) = try await make()
        try write("hello\r\nworld\r\n", to: dir + "/a.txt")
        var opened: [String] = []
        ws.opened = { opened.append($0) }

        let doc = try await ws.open(dir + "/a.txt")
        #expect(ws.selectedPath == doc.remotePath)
        #expect(try ws.text(of: doc) == "hello\r\nworld\r\n", "CRLF stays as it is")
        #expect(try await ws.open(dir + "/a.txt") === doc, "opening again selects the tab")
        #expect(opened == [dir + "/a.txt"])

        doc.isModified = true
        try await ws.save(doc, text: "changed\r\n")
        #expect(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8) == "changed\r\n")
        #expect(!doc.isModified && !doc.isSaving)
        await ws.session.close()
    }

    @Test func latin1FileRoundTrips() async throws {
        let (ws, dir) = try await make()
        try Data([0x67, 0x72, 0xFC, 0xDF, 0x0A]).write(to: URL(fileURLWithPath: dir + "/old.txt"))
        let doc = try await ws.open(dir + "/old.txt")
        let text = try ws.text(of: doc)
        #expect(doc.encoding == .latin1)
        try await ws.save(doc, text: text + "äöü\n")
        #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/old.txt")) == Data([0x67, 0x72, 0xFC, 0xDF, 0x0A, 0xE4, 0xF6, 0xFC, 0x0A]))
        await ws.session.close()
    }

    @Test func binaryFilesAreRefusedImagesAreNot() async throws {
        let (ws, dir) = try await make()
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: URL(fileURLWithPath: dir + "/a.zip"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: URL(fileURLWithPath: dir + "/p.png"))
        await #expect(throws: WorkspaceError.binary("a.zip")) { try await ws.open(dir + "/a.zip") }
        #expect(ws.documents.isEmpty)
        #expect(try await ws.open(dir + "/p.png").kind == .image)
        await ws.session.close()
    }

    @Test func pollReloadsCleanFilesAndAsksAboutEditedOnes() async throws {
        let (ws, dir) = try await make()
        try write("one", to: dir + "/clean.txt")
        try write("one", to: dir + "/edited.txt")
        let clean = try await ws.open(dir + "/clean.txt")
        let edited = try await ws.open(dir + "/edited.txt")
        edited.isModified = true

        var reloaded: [String: String] = [:]
        var asked: [String] = []
        ws.reload = { doc, text in reloaded[doc.name] = text }
        ws.askToReload = { doc in asked.append(doc.name); return false }

        await ws.poll()
        #expect(reloaded.isEmpty && asked.isEmpty, "nothing changed yet")

        try write("two", to: dir + "/clean.txt", mtimeOffset: 10)
        try write("two", to: dir + "/edited.txt", mtimeOffset: 10)
        await ws.poll()
        #expect(reloaded == ["clean.txt": "two"])
        #expect(asked == ["edited.txt"])
        #expect(edited.isModified, "declined: local edits stay")

        // Asked once per change, not on every poll.
        await ws.poll()
        #expect(asked == ["edited.txt"])

        // A touch without new content doesn't disturb the tab.
        reloaded = [:]
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: dir + "/clean.txt")
        await ws.poll()
        #expect(reloaded.isEmpty)
        _ = clean
        await ws.session.close()
    }

    @Test func acceptingReloadReplacesEdits() async throws {
        let (ws, dir) = try await make()
        try write("one", to: dir + "/f.txt")
        let doc = try await ws.open(dir + "/f.txt")
        doc.isModified = true
        var reloaded: String?
        ws.reload = { _, text in reloaded = text }
        ws.askToReload = { _ in true }
        try write("theirs", to: dir + "/f.txt", mtimeOffset: 10)
        await ws.poll()
        #expect(reloaded == "theirs")
        #expect(!doc.isModified)
        await ws.session.close()
    }

    @Test func ownSaveIsNotARemoteChange() async throws {
        let (ws, dir) = try await make()
        try write("one", to: dir + "/f.txt")
        let doc = try await ws.open(dir + "/f.txt")
        var reloads = 0
        ws.reload = { _, _ in reloads += 1 }
        try await Task.sleep(for: .seconds(1.1))  // so the upload's mtime differs
        try await ws.save(doc, text: "mine")
        await ws.poll()
        #expect(reloads == 0)
        await ws.session.close()
    }

    @Test func deletedFilesAreMarkedAndRestoredBySaving() async throws {
        let (ws, dir) = try await make()
        try write("keep me", to: dir + "/f.txt")
        let doc = try await ws.open(dir + "/f.txt")
        try FileManager.default.removeItem(atPath: dir + "/f.txt")
        await ws.poll()
        #expect(doc.isDeleted)
        #expect(ws.hasUnsavedChanges)

        try await ws.upload(doc)
        #expect(!doc.isDeleted)
        #expect(try String(contentsOfFile: dir + "/f.txt", encoding: .utf8) == "keep me")
        await ws.session.close()
    }

    @Test func closingAndReopening() async throws {
        let (ws, dir) = try await make()
        for name in ["a", "b", "c"] { try write(name, to: "\(dir)/\(name).txt") }
        let a = try await ws.open(dir + "/a.txt")
        let b = try await ws.open(dir + "/b.txt")
        _ = try await ws.open(dir + "/c.txt")

        ws.selectedPath = b.remotePath
        ws.close(b)
        #expect(ws.selectedPath == dir + "/c.txt", "the tab to the right takes over")
        ws.close(ws.selected!)
        #expect(ws.selectedPath == a.remotePath)
        #expect(!FileManager.default.fileExists(atPath: b.localURL.path), "a closed tab's temp copy goes")

        #expect(try await ws.reopenClosed()?.name == "c.txt")
        #expect(try await ws.reopenClosed()?.name == "b.txt")
        #expect(!ws.canReopenClosed)
        #expect(ws.documents.map(\.name) == ["a.txt", "c.txt", "b.txt"])
        await ws.session.close()
    }
}
