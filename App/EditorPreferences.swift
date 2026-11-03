// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import EdithEditor
import Foundation

/// Editor and file preferences, stored under the Linux app's keys so a
/// shared or imported servers.json carries them over.
struct EditorPreferences: Equatable {
    /// Monaco theme id; empty follows the system appearance.
    var scheme = ""
    /// Font family name; empty is the system monospaced font (SF Mono).
    var font = ""
    var fontSize = 13
    var ligatures = false
    var minimap = false
    var stickyScroll = false
    var formatOnSave = false
    var insertSpaces = true
    var tabSize = 4
    /// none, boundary, selection, trailing, all
    var renderWhitespace = "selection"
    /// on, off, relative, interval
    var lineNumbers = "on"
    /// Raw Monaco options as a JSON object.
    var overrides = "{}"
    /// Extension (no dot) to Monaco language id.
    var syntaxAssociations: [String: String] = [:]
    var singleClickOpen = false

    static func load(from config: ConfigStore) -> EditorPreferences {
        var p = EditorPreferences()
        p.scheme = config.preference("syntax_scheme") ?? p.scheme
        p.font = config.preference("editor_font") ?? p.font
        // The Linux app stores 0 for "default".
        if let size: Int = config.preference("editor_font_size"), size > 0 { p.fontSize = size }
        p.ligatures = config.preference("editor_font_ligatures") ?? p.ligatures
        p.minimap = config.preference("editor_minimap") ?? p.minimap
        p.stickyScroll = config.preference("editor_sticky_scroll") ?? p.stickyScroll
        p.formatOnSave = config.preference("editor_format_on_save") ?? p.formatOnSave
        p.insertSpaces = config.preference("editor_insert_spaces") ?? p.insertSpaces
        p.tabSize = config.preference("editor_tab_size") ?? p.tabSize
        p.renderWhitespace = config.preference("editor_render_whitespace") ?? p.renderWhitespace
        p.lineNumbers = config.preference("editor_line_numbers") ?? p.lineNumbers
        p.overrides = config.preferenceJSON("editor_overrides") ?? p.overrides
        p.syntaxAssociations = config.preference("syntax_associations") ?? p.syntaxAssociations
        p.singleClickOpen = config.preference("single_click_open") ?? p.singleClickOpen
        return p
    }

    /// Writes the values that differ from `old`.
    func save(to config: ConfigStore, replacing old: EditorPreferences) throws {
        if scheme != old.scheme { try config.setPreference("syntax_scheme", scheme) }
        if font != old.font { try config.setPreference("editor_font", font) }
        if fontSize != old.fontSize { try config.setPreference("editor_font_size", fontSize) }
        if ligatures != old.ligatures { try config.setPreference("editor_font_ligatures", ligatures) }
        if minimap != old.minimap { try config.setPreference("editor_minimap", minimap) }
        if stickyScroll != old.stickyScroll { try config.setPreference("editor_sticky_scroll", stickyScroll) }
        if formatOnSave != old.formatOnSave { try config.setPreference("editor_format_on_save", formatOnSave) }
        if insertSpaces != old.insertSpaces { try config.setPreference("editor_insert_spaces", insertSpaces) }
        if tabSize != old.tabSize { try config.setPreference("editor_tab_size", tabSize) }
        if renderWhitespace != old.renderWhitespace { try config.setPreference("editor_render_whitespace", renderWhitespace) }
        if lineNumbers != old.lineNumbers { try config.setPreference("editor_line_numbers", lineNumbers) }
        if overrides != old.overrides { try config.setPreferenceJSON("editor_overrides", overrides) }
        if syntaxAssociations != old.syntaxAssociations { try config.setPreference("syntax_associations", syntaxAssociations) }
        if singleClickOpen != old.singleClickOpen { try config.setPreference("single_click_open", singleClickOpen) }
    }

    func configuration(dark: Bool) -> EditorConfiguration {
        var c = EditorConfiguration()
        c.theme = MonacoCatalog.resolveTheme(scheme, dark: dark)
        if !font.isEmpty { c.fontFamily = "'\(font.replacingOccurrences(of: "'", with: ""))', ui-monospace, monospace" }
        c.fontSize = fontSize
        c.settings.insertSpaces = insertSpaces
        c.settings.tabSize = tabSize
        c.settings.minimap = minimap
        c.settings.renderWhitespace = renderWhitespace
        c.settings.stickyScroll = stickyScroll
        c.settings.fontLigatures = ligatures
        c.settings.lineNumbers = lineNumbers
        c.customOptionsJSON = overrides
        c.formatOnSave = formatOnSave
        return c
    }

    func language(for fileName: String) -> String {
        MonacoCatalog.language(forFileName: fileName, associations: syntaxAssociations)
    }
}
