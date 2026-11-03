// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reports when another app saves a file, for uploading it.
///
/// Watches both the file and its folder: an editor that writes in place
/// changes only the file, one that writes a new file and renames it over
/// the old one changes only the folder. After such a swap the file watch
/// moves to the new file. Bursts of events per save are debounced, and a
/// callback only fires when the file's size, date or identity changed.
public final class FileWatcher: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "de.singular.edith.file-watcher")
    private let debounce: Duration
    private let changed: @Sendable () -> Void
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode = 0
    private var pending: DispatchWorkItem?
    private var signature: [AnyHashable]?
    private var cancelled = false

    public init?(url: URL, debounce: Duration = .milliseconds(600), changed: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.changed = changed
        guard let folder = watch(url.deletingLastPathComponent().path) else { return nil }
        folderSource = folder
        signature = Self.signature(of: url)
        queue.sync { watchFile() }
    }

    deinit {
        folderSource?.cancel()
        fileSource?.cancel()
    }

    public func cancel() {
        queue.sync {
            cancelled = true
            pending?.cancel()
            folderSource?.cancel()
            fileSource?.cancel()
        }
    }

    private func watch(_ path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// (Re)watches the file now at `url`, if it's a different one than before.
    private func watchFile() {
        let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int ?? 0
        guard inode != watchedInode || fileSource == nil else { return }
        fileSource?.cancel()
        fileSource = inode == 0 ? nil : watch(url.path)
        watchedInode = inode
    }

    private func schedule() {
        guard !cancelled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        let delay = Double(debounce.components.seconds) + Double(debounce.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func check() {
        guard !cancelled else { return }
        watchFile()
        guard let now = Self.signature(of: url), now != signature else { return }
        signature = now
        changed()
    }

    /// What identifies a version of the file: inode, size and modification time.
    private static func signature(of url: URL) -> [AnyHashable]? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return [a[.systemFileNumber] as? Int ?? 0, a[.size] as? Int ?? 0, a[.modificationDate] as? Date ?? .distantPast]
    }
}
