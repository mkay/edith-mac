// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// How a file's text is stored, so saving writes it back the same way.
public enum TextEncoding: String, Sendable {
    case utf8
    /// Anything that isn't valid UTF-8. ISO Latin-1 maps every byte to a
    /// character, so the file round-trips unchanged where the Linux app's
    /// `errors="replace"` would write U+FFFD over every non-UTF-8 byte.
    case latin1

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .latin1: "Latin-1"
        }
    }
}

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case binary(String)
    case cantEncode(String, TextEncoding)

    public var errorDescription: String? {
        switch self {
        case .binary(let name): String(localized: "“\(name)” looks like a binary file, which the editor can't show.", bundle: .module)
        case .cantEncode(let name, let encoding):
            String(localized: "“\(name)” is a \(encoding.displayName) file, and some of the new text can't be written in \(encoding.displayName).", bundle: .module)
        }
    }
}

public enum TextCodec {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The text in `data`, or nil if it looks binary (a NUL byte early on).
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncoding, bom: Bool)? {
        if data.prefix(8000).contains(0) { return nil }
        let hasBOM = data.starts(with: bom)
        if let text = String(data: hasBOM ? data.dropFirst(3) : data, encoding: .utf8) {
            return (text, .utf8, hasBOM)
        }
        return String(data: data, encoding: .isoLatin1).map { ($0, .latin1, false) }
    }

    public static func encode(_ text: String, as encoding: TextEncoding, bom: Bool, name: String) throws -> Data {
        switch encoding {
        case .utf8:
            return (bom ? Data(self.bom) : Data()) + Data(text.utf8)
        case .latin1:
            guard let data = text.data(using: .isoLatin1) else { throw WorkspaceError.cantEncode(name, .latin1) }
            return data
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "tiff", "tif", "avif"]
}

/// A file open in a tab: its local copy and what's known about the remote one.
@MainActor
@Observable
public final class Document: Identifiable {
    public enum Kind: Sendable { case text, image }

    public let remotePath: String
    public let localURL: URL
    public let kind: Kind
    /// Set by the editor as the buffer diverges from what was loaded or saved.
    public var isModified = false
    /// The file disappeared from the server; the tab holds the only copy.
    public internal(set) var isDeleted = false
    public internal(set) var isSaving = false
    public internal(set) var encoding = TextEncoding.utf8
    public internal(set) var hasBOM = false
    /// The server's mtime as of the last download or upload.
    var remoteModified: Date?
    /// A "changed on the server" question is showing; don't ask twice.
    var isAskingAboutRemoteChange = false

    public nonisolated var id: String { remotePath }
    public var name: String { remoteName(remotePath) }

    init(remotePath: String, localURL: URL, kind: Kind) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.kind = kind
    }
}

/// The files open in a window's editor: opening (download), saving (upload),
/// and watching the server for changes, as the Linux app's window does.
@MainActor
@Observable
public final class Workspace {
    public let session: Session
    public private(set) var documents: [Document] = []
    public var selectedPath: String?

    /// New text for a document whose file changed on the server.
    @ObservationIgnored public var reload: (Document, String) -> Void = { _, _ in }
    /// The file changed on the server while edited here. Return true to
    /// reload it (losing the local edits).
    @ObservationIgnored public var askToReload: (Document) async -> Bool = { _ in false }
    /// A file was opened, for the recent files list.
    @ObservationIgnored public var opened: (String) -> Void = { _ in }

    private var closedPaths: [String] = []
    private let tempFiles: TempFiles
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pollInFlight = false

    public init(session: Session, tempFiles: TempFiles = .shared) {
        self.session = session
        self.tempFiles = tempFiles
    }

    public var selected: Document? { documents.first { $0.remotePath == selectedPath } }
    public var hasUnsavedChanges: Bool { documents.contains { $0.isModified || $0.isDeleted } }
    public var canReopenClosed: Bool { !closedPaths.isEmpty }

    public func document(at remotePath: String) -> Document? {
        documents.first { $0.remotePath == remotePath }
    }

    // MARK: Opening

    /// Opens a file in a tab, downloading it, or selects its tab if it's open.
    @discardableResult
    public func open(_ remotePath: String) async throws -> Document {
        if let existing = document(at: remotePath) {
            selectedPath = remotePath
            return existing
        }
        let local = try tempFiles.path(for: remotePath)
        let ext = (remotePath as NSString).pathExtension.lowercased()
        let doc = Document(remotePath: remotePath, localURL: local,
                           kind: TextCodec.imageExtensions.contains(ext) ? .image : .text)

        try await session.download(RemoteFile(name: remoteName(remotePath), path: remotePath), to: local)
        if doc.kind == .text, TextCodec.decode(try Data(contentsOf: local)) == nil {
            try? FileManager.default.removeItem(at: local)
            throw WorkspaceError.binary(doc.name)
        }
        doc.remoteModified = try? await session.client.stat(remotePath).modified

        // Opened twice in quick succession: keep the first.
        if let existing = document(at: remotePath) {
            selectedPath = remotePath
            return existing
        }
        documents.append(doc)
        selectedPath = remotePath
        opened(remotePath)
        return doc
    }

    /// The text of a document's local copy, noting its encoding for saving.
    public func text(of doc: Document) throws -> String {
        guard let decoded = TextCodec.decode(try Data(contentsOf: doc.localURL)) else {
            throw WorkspaceError.binary(doc.name)
        }
        doc.encoding = decoded.encoding
        doc.hasBOM = decoded.bom
        return decoded.text
    }

    // MARK: Saving

    /// Writes the text locally and uploads it. A save already under way for
    /// the same document makes this a no-op, so a doubled ⌘S uploads once.
    public func save(_ doc: Document, text: String) async throws {
        guard !doc.isSaving else { return }
        let data = try TextCodec.encode(text, as: doc.encoding, bom: doc.hasBOM, name: doc.name)
        try data.write(to: doc.localURL, options: .atomic)
        try await upload(doc)
        doc.isModified = false
    }

    /// Uploads the local copy as it is (an image, or a deleted file restored).
    public func upload(_ doc: Document) async throws {
        doc.isSaving = true
        defer { doc.isSaving = false }
        try await session.upload([doc.localURL], to: remoteParent(doc.remotePath), overwrite: true)
        // Recorded before saving ends, so the poller never mistakes our
        // own upload for someone else's change.
        doc.remoteModified = try? await session.client.stat(doc.remotePath).modified
        doc.isDeleted = false
    }

    // MARK: Closing

    public func close(_ doc: Document) {
        guard let index = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: index)
        closedPaths.removeAll { $0 == doc.remotePath }
        closedPaths.append(doc.remotePath)
        if closedPaths.count > 10 { closedPaths.removeFirst() }
        if selectedPath == doc.remotePath {
            selectedPath = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].remotePath
        }
        try? FileManager.default.removeItem(at: doc.localURL.deletingLastPathComponent())
    }

    /// Reopens the most recently closed tab.
    @discardableResult
    public func reopenClosed() async throws -> Document? {
        guard let path = closedPaths.popLast() else { return nil }
        return try await open(path)
    }

    // MARK: Watching the server

    public func startPolling(every interval: Duration = .seconds(3)) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.poll()
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// Checks each open file on the server once. A file that changed is
    /// reloaded if it has no local edits, and asked about if it has; one
    /// that vanished is marked deleted.
    public func poll() async {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        for doc in documents where !doc.isSaving && !doc.isAskingAboutRemoteChange {
            let current: RemoteFile
            do {
                current = try await session.client.stat(doc.remotePath)
            } catch RemoteError.noSuchFile {
                if !doc.isSaving { doc.isDeleted = true }
                continue
            } catch {
                continue  // transient; leave things as they are
            }
            doc.isDeleted = false
            // A save that started while we were asking bumps the mtime itself.
            guard !doc.isSaving, documents.contains(where: { $0 === doc }),
                  current.modified != doc.remoteModified else { continue }
            doc.remoteModified = current.modified

            if doc.isModified {
                doc.isAskingAboutRemoteChange = true
                let reload = await askToReload(doc)
                doc.isAskingAboutRemoteChange = false
                guard reload else { continue }
            }
            await redownload(doc)
        }
    }

    /// Fetches the file again and hands over its text, unless only the
    /// mtime moved (a touch, an rsync): then the tab isn't disturbed.
    public func redownload(_ doc: Document) async {
        let before = try? Data(contentsOf: doc.localURL)
        do {
            let fs = await session.transferConnection()
            try await fs.download(doc.remotePath, to: doc.localURL, progress: nil)
        } catch {
            return
        }
        guard let after = try? Data(contentsOf: doc.localURL), after != before else { return }
        if doc.kind == .image {
            reload(doc, "")
        } else if let text = try? text(of: doc) {
            reload(doc, text)
            doc.isModified = false
        }
    }
}
