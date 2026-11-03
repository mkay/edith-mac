// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Called as bytes move: (done, total). `total` is 0 when unknown.
public typealias TransferProgress = @Sendable (_ done: UInt64, _ total: UInt64) -> Void

public enum RemoteError: Error, LocalizedError, Equatable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    /// The user declined to trust an unknown host key.
    case hostKeyRejected
    /// The host key differs from the one on record. Possibly an attack.
    case hostKeyChanged(host: String, keyType: String, fingerprint: String)
    case hostKeyRevoked(host: String)
    case noSuchFile(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case unsupported(String)
    /// Any other error, with the server's or library's message.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected.", bundle: .module)
        case .connectionFailed(let m): String(localized: "Connection failed: \(m)", bundle: .module)
        case .authenticationFailed(let m): String(localized: "Authentication failed: \(m)", bundle: .module)
        case .hostKeyRejected: String(localized: "The server's host key was not accepted.", bundle: .module)
        case .hostKeyChanged(let host, let type, let fp):
            String(localized: "The host key for \(host) has changed. The server now presents \(type) \(fp), which doesn't match the key on record. This can mean someone is intercepting the connection.", bundle: .module)
        case .hostKeyRevoked(let host): String(localized: "The host key for \(host) is marked as revoked.", bundle: .module)
        case .noSuchFile(let p): String(localized: "“\(remoteName(p))” doesn't exist.", bundle: .module)
        case .permissionDenied(let p): String(localized: "Permission denied: \(p)", bundle: .module)
        case .alreadyExists(let p): String(localized: "“\(remoteName(p))” already exists.", bundle: .module)
        case .unsupported(let m): m
        case .failed(let m): m
        }
    }
}

public struct ExecResult: Equatable, Sendable {
    public var status: Int
    public var stdout: String
    public var stderr: String
}

/// A connected remote file system: the operations the browser, editor and
/// transfers need, independent of protocol. SFTP and FTP implement it.
///
/// Long operations check for task cancellation between chunks and throw
/// `CancellationError`.
public protocol RemoteFileSystem: Actor {
    var isConnected: Bool { get }
    /// Whether `exec` works here (SSH exec allowed). False for FTP.
    var canExec: Bool { get }
    func close() async

    /// Resolves a path on the server (`.`, `~`, symlinks) to an absolute one.
    func normalize(_ path: String) async throws -> String
    /// Directory contents, without `.` and `..`.
    func list(_ path: String) async throws -> [RemoteFile]
    /// Follows symlinks.
    func stat(_ path: String) async throws -> RemoteFile

    func download(_ remotePath: String, to localURL: URL, progress: TransferProgress?) async throws
    /// Fails with `.alreadyExists` unless `overwrite`.
    func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: TransferProgress?) async throws

    func mkdir(_ path: String) async throws
    /// Fails with `.alreadyExists` rather than replacing the destination.
    func rename(_ from: String, to: String) async throws
    func chmod(_ path: String, permissions: UInt32) async throws
    func remove(_ path: String) async throws
    func rmdir(_ path: String) async throws
    /// Creates an empty file, failing if one exists.
    func createFile(_ path: String) async throws
    /// Copies a file on the server. Fails with `.alreadyExists` if `to` exists.
    func copyFile(_ from: String, to: String) async throws

    func exec(_ command: String) async throws -> ExecResult
}

// MARK: - Operations built from the primitives

extension RemoteFileSystem {
    public func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await stat(path)
            return true
        } catch RemoteError.noSuchFile {
            return false
        }
    }

    /// Deletes a directory and everything in it. Symlinks are removed, not followed.
    public func removeRecursive(_ path: String) async throws {
        for entry in try await list(path) {
            try Task.checkCancellation()
            if entry.isDirectory && !entry.isSymlink {
                try await removeRecursive(entry.path)
            } else {
                try await remove(entry.path)
            }
        }
        try await rmdir(path)
    }

    /// Copies a file or directory tree on the server.
    public func copyRecursive(_ from: String, to: String) async throws {
        guard try await !exists(to) else { throw RemoteError.alreadyExists(to) }
        try await copyTree(from, to: to)
    }

    private func copyTree(_ from: String, to: String) async throws {
        try Task.checkCancellation()
        guard try await stat(from).isDirectory else {
            try await copyFile(from, to: to)
            return
        }
        try await mkdir(to)
        for entry in try await list(from) {
            try await copyTree(entry.path, to: remoteJoin(to, entry.name))
        }
    }

    /// Total size of the files under `path`.
    public func treeSize(_ path: String) async throws -> UInt64 {
        var total: UInt64 = 0
        for entry in try await list(path) {
            try Task.checkCancellation()
            total += entry.isDirectory && !entry.isSymlink ? try await treeSize(entry.path) : entry.size
        }
        return total
    }

    /// Downloads a file or a whole directory tree. Progress covers the tree.
    public func downloadTree(_ remotePath: String, to localURL: URL, progress: TransferProgress?) async throws {
        let root = try await stat(remotePath)
        guard root.isDirectory else {
            try await download(remotePath, to: localURL, progress: progress)
            return
        }
        let total = try await treeSize(remotePath)
        let counter = ByteCounter()
        try await downloadDirectory(remotePath, to: localURL) { done, _ in
            progress?(counter.add(done), total)
        }
    }

    private func downloadDirectory(_ remotePath: String, to localURL: URL, progress: @escaping TransferProgress) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        for entry in try await list(remotePath) {
            try Task.checkCancellation()
            let local = localURL.appending(path: entry.name)
            if entry.isDirectory && !entry.isSymlink {
                try await downloadDirectory(entry.path, to: local, progress: progress)
            } else {
                // Per-file progress arrives as running totals; turn them into deltas.
                let last = ByteCounter()
                try await download(entry.path, to: local) { done, _ in
                    progress(done - last.set(done), 0)
                }
            }
        }
    }

    /// Uploads a local directory tree. Fails with `.alreadyExists` if the
    /// destination exists, unless `overwrite`.
    public func uploadDirectory(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: TransferProgress?) async throws {
        if try await exists(remotePath) {
            guard overwrite else { throw RemoteError.alreadyExists(remotePath) }
        } else {
            try await mkdir(remotePath)
        }
        let files = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        let total = (files?.allObjects as? [URL] ?? []).reduce(UInt64(0)) { sum, url in
            sum + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let counter = ByteCounter()
        try await uploadContents(of: localURL, to: remotePath) { delta, _ in
            progress?(counter.add(delta), total)
        }
    }

    private func uploadContents(of localURL: URL, to remotePath: String, progress: @escaping TransferProgress) async throws {
        let children = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            try Task.checkCancellation()
            let remote = remoteJoin(remotePath, child.lastPathComponent)
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if try await !exists(remote) { try await mkdir(remote) }
                try await uploadContents(of: child, to: remote, progress: progress)
            } else {
                let last = ByteCounter()
                try await upload(child, to: remote, overwrite: true) { done, _ in
                    progress(done - last.set(done), 0)
                }
            }
        }
    }
}

/// A counter shared with progress callbacks, which run on the connection's queue.
final class ByteCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private let lock = NSLock()

    /// Adds `delta` and returns the new total.
    func add(_ delta: UInt64) -> UInt64 {
        lock.withLock { value += delta; return value }
    }

    /// Stores `new` and returns the previous value.
    func set(_ new: UInt64) -> UInt64 {
        lock.withLock { defer { value = new }; return value }
    }
}
