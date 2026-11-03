// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// Local copies of remote files being edited.
///
/// Each file gets its own random subdirectory so two remote files with the
/// same name never collide, and keeps its real name so editors and Quick
/// Look see the right extension.
public final class TempFiles: Sendable {
    public static let shared = TempFiles()

    private let parent: URL
    private let base = Mutex<URL?>(nil)

    public init(parent: URL = FileManager.default.temporaryDirectory) {
        self.parent = parent
    }

    /// A fresh local path for `remotePath`. The directory exists; the file doesn't.
    public func path(for remotePath: String) throws -> URL {
        let root = try base.withLock { base in
            if let base, FileManager.default.fileExists(atPath: base.path) { return base }
            let dir = parent.appending(path: "edith-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            base = dir
            return dir
        }
        let name = remotePath.split(separator: "/").last.map(String.init) ?? "untitled"
        let dir = root.appending(path: String(UUID().uuidString.prefix(8).lowercased()), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
    }

    /// Removes every temp file. Call on quit.
    public func cleanup() {
        base.withLock { base in
            if let base { try? FileManager.default.removeItem(at: base) }
            base = nil
        }
    }
}
