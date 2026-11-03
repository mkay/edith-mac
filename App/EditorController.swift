// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import EdithEditor
import Foundation
import Observation

/// One tab: its document, its Monaco instance (for text) and what the
/// status bar shows about it.
@MainActor
@Observable
final class EditorTab: Identifiable {
    let document: Document
    private(set) var bridge: EditorBridge?
    var line = 1
    var column = 1
    var lineEnding = "lf"
    var wordWrap = true
    var language = "plaintext"
    var insertSpaces = true
    var tabSize = 4
    /// Bumped when an image's file changes on disk, to redraw it.
    var revision = 0
    var showPreview = true

    @ObservationIgnored var snapshot: String?
    @ObservationIgnored var saveWaiter: CheckedContinuation<String, Never>?
    @ObservationIgnored var isSaving = false

    nonisolated var id: String { document.id }
    var isSVG: Bool { (document.name as NSString).pathExtension.lowercased() == "svg" }

    init(document: Document) {
        self.document = document
    }

    func attach(_ bridge: EditorBridge) {
        self.bridge = bridge
    }
}

/// The editor of one connection: tabs, saving, closing and the questions
/// that come with them.
@MainActor
@Observable
final class EditorController {
    let workspace: Workspace
    private(set) var tabs: [String: EditorTab] = [:]
    @ObservationIgnored private var configuration = EditorConfiguration()
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private weak var window: WindowModel?

    init(workspace: Workspace, app: AppModel, window: WindowModel) {
        self.workspace = workspace
        self.app = app
        self.window = window

        workspace.reload = { [weak self] doc, text in self?.reloaded(doc, text: text) }
        workspace.askToReload = { [weak self] doc in await self?.askToReload(doc) ?? false }
        let serverID = workspace.session.server.id
        workspace.opened = { [app] path in try? app.config.pushRecent(serverID: serverID, path: path) }
        workspace.startPolling()
    }

    var orderedTabs: [EditorTab] { workspace.documents.compactMap { tabs[$0.remotePath] } }
    var selected: EditorTab? { workspace.selectedPath.flatMap { tabs[$0] } }
    var hasUnsavedChanges: Bool { workspace.hasUnsavedChanges }

    func select(_ tab: EditorTab) {
        workspace.selectedPath = tab.id
    }

    func shutdown() {
        workspace.stopPolling()
    }

    /// Applies new preferences, or a new light/dark theme, to every editor.
    func apply(_ new: EditorConfiguration) {
        let old = configuration
        configuration = new
        guard new != old else { return }
        for tab in tabs.values { tab.bridge?.apply(new, replacing: old) }
    }

    // MARK: Opening

    func open(_ remotePath: String) async throws {
        let doc = try await workspace.open(remotePath)
        guard tabs[doc.id] == nil else { return }
        let tab = EditorTab(document: doc)
        tabs[doc.id] = tab
        if doc.kind == .text {
            try startEditor(for: tab, text: workspace.text(of: doc))
        }
    }

    private func startEditor(for tab: EditorTab, text: String, dirty: Bool = false) throws {
        let bridge = EditorBridge()
        bridge.onEvent = { [weak self, weak tab] event in
            guard let self, let tab else { return }
            handle(event, from: tab)
        }
        tab.language = app.editorPreferences.language(for: tab.document.name)
        tab.insertSpaces = configuration.settings.insertSpaces
        tab.tabSize = configuration.settings.tabSize
        bridge.load(text, language: tab.language, configuration: configuration)
        if dirty { bridge.markDirty() }
        tab.attach(bridge)
    }

    private func handle(_ event: EditorEvent, from tab: EditorTab) {
        switch event {
        case .modifiedChanged(let modified): tab.document.isModified = modified
        case .cursorChanged(let line, let column): (tab.line, tab.column) = (line, column)
        case .initComplete(let eol, let wrap): (tab.lineEnding, tab.wordWrap) = (eol, wrap)
        case .wrapChanged(let wrap): tab.wordWrap = wrap
        case .saveRequested: Task { await save(tab) }
        case .saveContent(let text):
            tab.saveWaiter?.resume(returning: text)
            tab.saveWaiter = nil
        case .contentSnapshot(let text): tab.snapshot = text
        case .closeRequested: Task { await close(tab) }
        case .processTerminated: recover(tab)
        case .ready, .historyReset, .console: break
        }
    }

    /// The web content process died. Undo history is lost; the text isn't:
    /// rebuild from the last snapshot, still marked unsaved.
    private func recover(_ tab: EditorTab) {
        let text = tab.snapshot ?? (try? workspace.text(of: tab.document)) ?? ""
        try? startEditor(for: tab, text: text, dirty: tab.snapshot != nil)
    }

    // MARK: Saving

    /// Saves a tab to the server. Returns whether it worked.
    @discardableResult
    func save(_ tab: EditorTab) async -> Bool {
        guard !tab.isSaving else { return false }
        tab.isSaving = true
        defer { tab.isSaving = false }

        do {
            guard let bridge = tab.bridge else {
                // An image restored after it vanished from the server.
                try await workspace.upload(tab.document)
                return true
            }
            let text = await withCheckedContinuation { continuation in
                tab.saveWaiter = continuation
                bridge.savePrepare(format: configuration.formatOnSave)
            }
            try await workspace.save(tab.document, text: text)
            // Only what was uploaded counts as saved: typing during the
            // upload keeps the tab dirty.
            if try await bridge.evaluate("EdithBridge.getContent()") as? String == text {
                bridge.markClean()
            } else {
                tab.document.isModified = true
            }
            if tab.isSVG { tab.revision += 1 }
            return true
        } catch {
            tab.document.isModified = true
            window?.message = Message(title: "Couldn't Save “\(tab.document.name)”", text: error.localizedDescription)
            return false
        }
    }

    func saveSelected() async {
        if let tab = selected { await save(tab) }
    }

    // MARK: Closing

    /// Closes a tab, asking first if it has unsaved changes or its file is
    /// gone from the server. Returns whether it closed.
    @discardableResult
    func close(_ tab: EditorTab) async -> Bool {
        guard let window else { return false }
        let doc = tab.document
        if doc.isDeleted {
            let choice = await window.choose(
                title: "File Was Deleted",
                message: "“\(doc.name)” no longer exists on the server. Closing the tab loses its content.",
                buttons: [.init("Restore"), .init("Close", role: .destructive)]
            )
            switch choice {
            case 0:
                await save(tab)
                return false
            case 1: break
            default: return false
            }
        } else if doc.isModified {
            let choice = await window.choose(
                title: "Save Changes?",
                message: "“\(doc.name)” has unsaved changes.",
                buttons: [.init("Save"), .init("Don't Save", role: .destructive)]
            )
            switch choice {
            case 0: guard await save(tab) else { return false }
            case 1: break
            default: return false
            }
        }
        workspace.close(doc)
        tabs.removeValue(forKey: doc.id)
        return true
    }

    func closeSelected() async {
        if let tab = selected { await close(tab) }
    }

    func closeOthers(than keep: EditorTab) async {
        for tab in orderedTabs where tab !== keep {
            guard await close(tab) else { return }
        }
    }

    func closeToRight(of anchor: EditorTab) async {
        guard let index = orderedTabs.firstIndex(where: { $0 === anchor }) else { return }
        for tab in orderedTabs[(index + 1)...] {
            guard await close(tab) else { return }
        }
    }

    func reopenClosed() async {
        do {
            guard let doc = try await workspace.reopenClosed() else { return }
            if tabs[doc.id] == nil {
                let tab = EditorTab(document: doc)
                tabs[doc.id] = tab
                if doc.kind == .text { try startEditor(for: tab, text: workspace.text(of: doc)) }
            }
        } catch {
            window?.message = Message(title: "Couldn't Reopen", text: error.localizedDescription)
        }
    }

    // MARK: Remote changes

    private func reloaded(_ doc: Document, text: String) {
        guard let tab = tabs[doc.id] else { return }
        if let bridge = tab.bridge {
            bridge.setContent(text)
        }
        tab.revision += 1
    }

    private func askToReload(_ doc: Document) async -> Bool {
        await window?.choose(
            title: "File Changed on Server",
            message: "“\(doc.name)” has been modified on the server. Reload it? Your unsaved changes will be lost.",
            buttons: [.init("Reload", role: .destructive), .init("Keep Mine")]
        ) == 0
    }
}
