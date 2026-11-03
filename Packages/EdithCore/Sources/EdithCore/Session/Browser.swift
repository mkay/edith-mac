// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// The file browser's state and operations: the current directory, history,
/// filtering and sorting, and the file operations of the context menu.
/// Each operation reloads the directory afterwards, as the Linux app does.
@MainActor
@Observable
public final class Browser {
    public enum SortKey: String, CaseIterable, Sendable {
        case name, size, modified, permissions, owner, group
    }

    public let session: Session
    private var client: any RemoteFileSystem { session.client }

    public private(set) var path: String
    /// Everything in the directory, as listed.
    public private(set) var entries: [RemoteFile] = [] { didSet { updateVisible() } }
    /// Filtered and sorted: folders first, then files.
    public private(set) var visible: [RemoteFile] = []
    public private(set) var isLoading = false
    public private(set) var error: String?

    public var showHidden = false { didSet { updateVisible() } }
    public var filter = "" { didSet { updateVisible() } }
    public var sortKey = SortKey.name { didSet { updateVisible() } }
    public var ascending = true { didSet { updateVisible() } }

    private var history: [String] = []
    private var historyIndex = -1
    @ObservationIgnored private var loadGeneration = 0

    public init(session: Session) {
        self.session = session
        self.path = session.startDirectory
    }

    // MARK: Navigation

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex < history.count - 1 }
    public var canGoUp: Bool { path != "/" }

    /// Lists `path` and makes it current. Results of an older request that
    /// finishes after a newer one are dropped.
    public func open(_ newPath: String, addToHistory: Bool = true) async {
        if addToHistory, history.isEmpty || history[historyIndex] != newPath {
            history = Array(history.prefix(historyIndex + 1)) + [newPath]
            historyIndex = history.count - 1
        }
        path = newPath
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let listed = try await client.list(newPath)
            guard generation == loadGeneration else { return }
            entries = listed
            error = nil
        } catch {
            guard generation == loadGeneration else { return }
            entries = []
            self.error = error.localizedDescription
        }
    }

    public func refresh() async {
        await open(path, addToHistory: false)
    }

    public func goBack() async {
        guard canGoBack else { return }
        historyIndex -= 1
        await open(history[historyIndex], addToHistory: false)
    }

    public func goForward() async {
        guard canGoForward else { return }
        historyIndex += 1
        await open(history[historyIndex], addToHistory: false)
    }

    public func goUp() async {
        guard canGoUp else { return }
        await open(remoteParent(path))
    }

    // MARK: Filtering and sorting

    private func updateVisible() {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = entries.filter { file in
            (showHidden || !file.name.hasPrefix("."))
                && (query.isEmpty || file.name.lowercased().contains(query))
        }
        visible = shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = compare(a, b)
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ a: RemoteFile, _ b: RemoteFile) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        switch sortKey {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .size: return cmp(a.isDirectory ? 0 : a.size, b.isDirectory ? 0 : b.size)
        case .modified: return cmp(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .permissions: return cmp(a.permissions, b.permissions)
        case .owner: return a.owner.localizedStandardCompare(b.owner)
        case .group: return a.group.localizedStandardCompare(b.group)
        }
    }

    // MARK: File operations

    /// Creates an empty file in the current directory and returns its path.
    @discardableResult
    public func createFile(named name: String) async throws -> String {
        let target = remoteJoin(path, try Self.validName(name))
        try await reloading { try await client.createFile(target) }
        return target
    }

    @discardableResult
    public func createFolder(named name: String) async throws -> String {
        let target = remoteJoin(path, try Self.validName(name))
        try await reloading { try await client.mkdir(target) }
        return target
    }

    @discardableResult
    public func rename(_ file: RemoteFile, to name: String) async throws -> String {
        let target = remoteJoin(remoteParent(file.path), try Self.validName(name))
        guard target != file.path else { return target }
        try await reloading { try await client.rename(file.path, to: target) }
        return target
    }

    /// Deletes files, and folders with everything in them. Symlinks are
    /// removed themselves, never followed.
    public func delete(_ files: [RemoteFile]) async throws {
        try await reloading {
            for file in files {
                if file.isDirectory && !file.isSymlink {
                    try await client.removeRecursive(file.path)
                } else {
                    try await client.remove(file.path)
                }
            }
        }
    }

    public func setPermissions(_ file: RemoteFile, to permissions: UInt32) async throws {
        try await reloading { try await client.chmod(file.path, permissions: permissions) }
    }

    /// Copies each item beside itself with a timestamp, as the Linux app
    /// does: `index_20261103-154500.php`.
    public func duplicate(_ files: [RemoteFile], date: Date = .now) async throws {
        let stamp = Self.stampFormatter.string(from: date)
        try await reloading {
            for file in files {
                let name: String
                if !file.isDirectory, let dot = file.name.lastIndex(of: "."), dot != file.name.startIndex {
                    name = "\(file.name[..<dot])_\(stamp)\(file.name[dot...])"
                } else {
                    name = "\(file.name)_\(stamp)"
                }
                try await client.copyRecursive(file.path, to: remoteJoin(remoteParent(file.path), name))
            }
        }
    }

    public func move(_ files: [RemoteFile], to directory: String) async throws {
        try await reloading {
            for file in files where remoteParent(file.path) != directory {
                try await client.rename(file.path, to: remoteJoin(directory, file.name))
            }
        }
    }

    public func copy(_ files: [RemoteFile], to directory: String) async throws {
        try await reloading {
            for file in files {
                try await client.copyRecursive(file.path, to: remoteJoin(directory, file.name))
            }
        }
    }

    /// Runs an operation, then reloads whether it worked or not, since a
    /// batch that failed halfway has still changed things.
    private func reloading(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// A single path component, or an error saying why not.
    public nonisolated static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw RemoteError.failed(String(localized: "The name can't be empty.", bundle: .module)) }
        if trimmed == "." || trimmed == ".." { throw RemoteError.failed(String(localized: "“\(trimmed)” isn't a valid name.", bundle: .module)) }
        if trimmed.contains("/") { throw RemoteError.failed(String(localized: "Names can't contain “/”.", bundle: .module)) }
        return trimmed
    }
}

/// The parent of a remote path; `/` is its own parent.
public func remoteParent(_ path: String) -> String {
    let parts = path.split(separator: "/")
    return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
}

/// A path and its ancestors, deepest first, ending with `/`.
public func remoteAncestors(_ path: String) -> [String] {
    let parts = path.split(separator: "/").map(String.init)
    return (0...parts.count).reversed().map { n in n == 0 ? "/" : "/" + parts.prefix(n).joined(separator: "/") }
}
