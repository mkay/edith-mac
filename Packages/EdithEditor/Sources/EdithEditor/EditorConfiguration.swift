// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension MonacoCatalog {
    /// Not in Monaco's list, which only has real languages.
    public static let plainText = Entry(id: "plaintext", name: "Plain Text")

    /// The language for a file name: a user association for its extension
    /// first, then the built-in table, then a few well-known bare names.
    public static func language(forFileName fileName: String, associations: [String: String] = [:]) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            if let lang = associations[ext] { return lang }
            if let lang = extensions[ext] { return lang }
        }
        switch fileName.lowercased() {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile", ".bashrc", ".bash_profile", ".zshrc", ".profile": return "shell"
        default: return "plaintext"
        }
    }

    public static func languageName(_ id: String) -> String {
        (languages + [plainText]).first { $0.id == id }?.name ?? id
    }

    /// A stored scheme, or the light or dark default when following the system.
    public static func resolveTheme(_ scheme: String, dark: Bool) -> String {
        scheme.isEmpty ? (dark ? "vs-dark" : "vs") : scheme
    }
}

/// Everything about how editors look and behave, from the preferences. The
/// same keys and values as the Linux app.
public struct EditorConfiguration: Equatable, Sendable {
    /// A Monaco theme id, already resolved (never "" for "follow system").
    public var theme = "vs-dark"
    /// CSS font family. `ui-monospace` is SF Mono, which web content can't
    /// name directly.
    public var fontFamily = "ui-monospace, Menlo, monospace"
    public var fontSize = 13
    public var wordWrap = true
    public var settings = EditorSettings()
    /// Raw Monaco options as JSON, merged over everything else.
    public var customOptionsJSON = "{}"
    public var formatOnSave = false

    public init() {}
}

extension EditorBridge {
    /// Loads a file's text with the given configuration.
    public func load(_ text: String, language: String, configuration c: EditorConfiguration) {
        callJSON("init", [json(text), json(language), json(c.theme), json(c.fontFamily), json(c.fontSize),
                          json(c.wordWrap), json(c.settings), c.customOptionsJSON])
    }

    /// Applies what changed between two configurations to a loaded editor.
    public func apply(_ new: EditorConfiguration, replacing old: EditorConfiguration) {
        if new.theme != old.theme { call("setTheme", new.theme) }
        if new.fontFamily != old.fontFamily || new.fontSize != old.fontSize { call("setFont", new.fontFamily, new.fontSize) }
        let s = new.settings, o = old.settings
        if s.insertSpaces != o.insertSpaces || s.tabSize != o.tabSize { setIndent(insertSpaces: s.insertSpaces, tabSize: s.tabSize) }
        if s.minimap != o.minimap { call("setMinimap", s.minimap) }
        if s.renderWhitespace != o.renderWhitespace { call("setRenderWhitespace", s.renderWhitespace) }
        if s.stickyScroll != o.stickyScroll { call("setStickyScroll", s.stickyScroll) }
        if s.fontLigatures != o.fontLigatures { call("setFontLigatures", s.fontLigatures) }
        if s.lineNumbers != o.lineNumbers { call("setLineNumbers", s.lineNumbers) }
        if new.customOptionsJSON != old.customOptionsJSON { callJSON("setCustomOptions", [new.customOptionsJSON]) }
    }

    public func setLanguage(_ id: String) { call("setLanguage", id) }
    public func setTheme(_ id: String) { call("setTheme", id) }
    public func setIndent(insertSpaces: Bool, tabSize: Int) { call("setIndent", insertSpaces, tabSize) }
    /// "lf" or "crlf".
    public func setLineEnding(_ eol: String) { call("setLineEnding", eol) }
    public func toggleWrap() { call("toggleWrap") }
    public func showFind() { call("showFind") }
    public func showReplace() { call("showReplace") }
    /// Monaco's own Go to Line box.
    public func gotoLine() { call("triggerAction", "editor.action.gotoLine") }
    public func toggleLineComment() { call("toggleLineComment") }
    public func undo() { call("undo") }
    public func redo() { call("redo") }
    public func markDirty() { call("markDirty") }
    public func focus() { webView.window?.makeFirstResponder(webView) }

    private func json(_ value: some Encodable) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
