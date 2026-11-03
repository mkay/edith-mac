// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tarGz = "tar.gz", tarBz2 = "tar.bz2", tarXz = "tar.xz", tar

    /// The format a name asks for, by its ending; nil if none matches.
    public init?(fileName: String) {
        let name = fileName.lowercased()
        switch true {
        case name.hasSuffix(".zip"): self = .zip
        case name.hasSuffix(".tar.gz"), name.hasSuffix(".tgz"): self = .tarGz
        case name.hasSuffix(".tar.bz2"), name.hasSuffix(".tbz2"): self = .tarBz2
        case name.hasSuffix(".tar.xz"), name.hasSuffix(".txz"): self = .tarXz
        case name.hasSuffix(".tar"): self = .tar
        default: return nil
        }
    }

    /// `name`, with `.zip` added if it has no archive ending.
    public static func normalized(_ name: String) -> (name: String, format: ArchiveFormat) {
        if let format = ArchiveFormat(fileName: name) { return (name, format) }
        return (name + ".zip", .zip)
    }

    /// The command that packs `item` (a name inside `directory`) into `archive`.
    func command(item: String, in directory: String, archive: String) -> (tool: String, args: [String]) {
        let tarFlag = ["tar.gz": "z", "tar.bz2": "j", "tar.xz": "J", "tar": ""][rawValue]
        if self == .zip { return ("zip", ["-qr", archive, item]) }
        return ("tar", ["-c\(tarFlag ?? "")f", archive, "-C", directory, item])
    }
}

/// Quotes a word for a POSIX shell.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension Session {
    /// Packs a file or folder into an archive beside it, named `name`
    /// (`.zip` is added if the name has no archive ending).
    ///
    /// With shell access the server packs it itself, which is fastest and
    /// keeps permissions. Otherwise (FTP, or exec refused) it's downloaded,
    /// packed here and uploaded; unlike the Linux app this works for
    /// folders too.
    @discardableResult
    public func createArchive(of file: RemoteFile, named name: String) async throws -> String {
        let (archiveName, format) = ArchiveFormat.normalized(try Browser.validName(name))
        let directory = remoteParent(file.path)
        let target = remoteJoin(directory, archiveName)
        if try await client.exists(target) { throw RemoteError.alreadyExists(target) }

        if canExec {
            let (tool, args) = format.command(item: file.name, in: directory, archive: target)
            let line = "cd \(shellQuote(directory)) && \(tool) " + args.map(shellQuote).joined(separator: " ")
            let result = try await client.exec(line)
            if result.status == 0 { return target }
            // A half-written archive mustn't be left behind.
            try? await client.remove(target)
        }

        let job: TransferQueue.Work = { [self] progress in
            let temp = FileManager.default.temporaryDirectory.appending(path: "edith-archive-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let fs = await transferConnection()
            try await fs.downloadTree(file.path, to: temp.appending(path: file.name), progress: nil)

            let archive = temp.appending(path: archiveName)
            let (tool, args) = format.command(item: file.name, in: temp.path, archive: archive.path)
            try await Self.run(tool, args, in: temp)
            try await fs.upload(archive, to: target, overwrite: false, progress: progress.callback)
        }
        try await transfers.perform("Archive \(file.name)", work: job)
        return target
    }

    /// Runs a command-line tool and waits for it without blocking a thread:
    /// waitUntilExit() needs a run loop, which Swift's task threads lack.
    private nonisolated static func run(_ tool: String, _ args: [String], in directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
        process.arguments = args
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RemoteError.failed(String(localized: "\(tool) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))", bundle: .module))
        }
    }
}
