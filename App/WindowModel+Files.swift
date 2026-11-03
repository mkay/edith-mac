// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import EdithEditor
import UniformTypeIdentifiers

/// The context menu's extras: other apps, tools, minify and archives.
extension WindowModel {
    // MARK: Opening in other apps

    /// The app a file opens with: the user's choice for its extension, else
    /// the system default.
    func defaultApp(for file: RemoteFile) -> URL? {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if let path = app.editorPreferences.appAssociations[ext], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(toOpen: Self.type(of: file))
    }

    /// Other apps that can open the file, by name.
    func otherApps(for file: RemoteFile) -> [URL] {
        let defaultApp = defaultApp(for: file)
        return NSWorkspace.shared.urlsForApplications(toOpen: Self.type(of: file))
            .filter { $0 != defaultApp }
            .sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
    }

    func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func type(of file: RemoteFile) -> UTType {
        file.isDirectory ? .folder : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
    }

    /// Downloads a file and opens it in another app. Saves made there are
    /// uploaded back for as long as the connection lasts. A folder is
    /// downloaded and shown in Finder, without the round trip.
    func openLocally(_ file: RemoteFile, with appURL: URL? = nil) {
        guard let connection else { return }
        Task {
            do {
                let local = try TempFiles.shared.path(for: file.path)
                try await connection.session.download(file, to: local)
                if file.isDirectory {
                    NSWorkspace.shared.activateFileViewerSelecting([local])
                    return
                }
                watchExternalEdits(of: file.path, at: local)
                if let app = appURL ?? defaultApp(for: file) {
                    _ = try await NSWorkspace.shared.open([local], withApplicationAt: app, configuration: .init())
                } else {
                    NSWorkspace.shared.open(local)
                }
            } catch is CancellationError {
            } catch {
                message = Message(title: String(localized: "Couldn't Open “\(file.name)”"), text: error.localizedDescription)
            }
        }
    }

    func chooseApp(for file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open “\(file.name)” With")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let app = panel.url else { return }
        openLocally(file, with: app)
    }

    private func watchExternalEdits(of remotePath: String, at local: URL) {
        guard let connection else { return }
        connection.externalEdits[remotePath]?.cancel()
        connection.externalEdits[remotePath] = FileWatcher(url: local) { [weak self] in
            Task { @MainActor in await self?.uploadExternalEdit(of: remotePath, from: local) }
        }
    }

    private func uploadExternalEdit(of remotePath: String, from local: URL) async {
        guard let connection else { return }
        do {
            try await connection.session.upload([local], to: remoteParent(remotePath), overwrite: true)
            announce(String(localized: "Uploaded \(remoteName(remotePath))"))
            if connection.browser.path == remoteParent(remotePath) { await connection.browser.refresh() }
            // An editor tab on the same file follows, unless it has its own edits.
            if let doc = connection.editor.workspace.document(at: remotePath), !doc.isModified {
                await connection.editor.workspace.redownload(doc)
            }
        } catch {
            message = Message(title: String(localized: "Couldn't Upload “\(remoteName(remotePath))”"), text: error.localizedDescription)
        }
    }

    // MARK: Tools

    /// The files in the tools folder, if one is set.
    var toolFiles: [URL] {
        let folder = app.editorPreferences.toolsFolder
        guard !folder.isEmpty else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func chooseToolsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Tools Folder")
        panel.message = String(localized: "Files in this folder can be uploaded anywhere with Upload Tool.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var prefs = app.editorPreferences
        prefs.toolsFolder = url.path
        try? app.setEditorPreferences(prefs)
    }

    // MARK: Minify and archives

    /// Writes `name.min.js` (or .css) beside the file. The source is never
    /// touched; an existing .min file is asked about before it's replaced.
    func minify(_ file: RemoteFile) {
        guard let connection, let kind = Minifier.Kind(fileName: file.name) else { return }
        Task {
            do {
                let source = try TempFiles.shared.path(for: file.path)
                try await connection.session.download(file, to: source)
                let code = try String(contentsOf: source, encoding: .utf8)
                let minified = try await Minifier.shared.minify(code, kind: kind)
                let directory = remoteParent(file.path)
                let output = try TempFiles.shared.path(for: remoteJoin(directory, Minifier.outputName(for: file.name)))
                try Data(minified.utf8).write(to: output)
                let saved = code.utf8.isEmpty ? 0 : 100 - minified.utf8.count * 100 / code.utf8.count
                upload([output], to: directory)
                announce(String(localized: "Minified \(file.name) (\(saved)% smaller)"))
            } catch {
                message = Message(title: String(localized: "Couldn't Minify “\(file.name)”"), text: error.localizedDescription)
            }
        }
    }

    func createArchive(of file: RemoteFile) {
        guard let connection else { return }
        nameRequest = NameRequest(title: String(localized: "Create Archive"), label: String(localized: "Name (.zip, .tar.gz, .tar.bz2, .tar.xz or .tar)"),
                                  initial: "\(file.name).zip", action: String(localized: "Create")) { [self] name in
            let path = try await connection.session.createArchive(of: file, named: name)
            await connection.browser.refresh()
            announce(String(localized: "Created \(remoteName(path))"))
        }
    }
}
