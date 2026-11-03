// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithEditor
import SwiftUI

/// Edith ▸ Settings. Changes apply to open editors right away and are
/// saved under the Linux app's preference keys.
struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            FileSettingsTab()
                .tabItem { Label("Files", systemImage: "doc") }
        }
        .frame(width: 520)
    }
}

/// Reads and writes AppModel.editorPreferences, saving each change.
private struct PreferencesBinding {
    let app: AppModel

    func callAsFunction<T>(_ keyPath: WritableKeyPath<EditorPreferences, T>) -> Binding<T> {
        Binding(
            get: { app.editorPreferences[keyPath: keyPath] },
            set: { value in
                var new = app.editorPreferences
                new[keyPath: keyPath] = value
                try? app.setEditorPreferences(new)
            }
        )
    }
}

private struct EditorSettingsTab: View {
    @Environment(AppModel.self) private var app
    @State private var overrides = ""
    @State private var overridesError: String?

    var body: some View {
        let pref = PreferencesBinding(app: app)
        Form {
            Section("Appearance") {
                Picker("Theme", selection: pref(\.scheme)) {
                    Text("Follow System").tag("")
                    Divider()
                    ForEach(MonacoCatalog.themes) { Text($0.name).tag($0.id) }
                }
                Picker("Font", selection: pref(\.font)) {
                    Text("System Monospaced (SF Mono)").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: pref(\.fontSize), in: 8...32) {
                    LabeledContent("Font Size", value: "\(app.editorPreferences.fontSize) pt")
                }
                Toggle("Font ligatures", isOn: pref(\.ligatures))
                Picker("Line Numbers", selection: pref(\.lineNumbers)) {
                    Text("On").tag("on")
                    Text("Relative").tag("relative")
                    Text("Every 10 Lines").tag("interval")
                    Text("Off").tag("off")
                }
                Toggle("Minimap", isOn: pref(\.minimap))
                Toggle("Sticky scroll", isOn: pref(\.stickyScroll))
                Picker("Show Whitespace", selection: pref(\.renderWhitespace)) {
                    Text("In Selection").tag("selection")
                    Text("Trailing").tag("trailing")
                    Text("Between Words").tag("boundary")
                    Text("Always").tag("all")
                    Text("Never").tag("none")
                }
            }

            Section("Editing") {
                Picker("Indent Using", selection: pref(\.insertSpaces)) {
                    Text("Spaces").tag(true)
                    Text("Tabs").tag(false)
                }
                Picker("Indent Width", selection: pref(\.tabSize)) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Format document on save", isOn: pref(\.formatOnSave))
            }

            Section {
                TextEditor(text: $overrides)
                    .font(.body.monospaced())
                    .frame(height: 110)
                HStack {
                    if let overridesError {
                        Text(overridesError).foregroundStyle(.red).font(.caption)
                    }
                    Spacer()
                    Button("Apply", action: applyOverrides)
                        .disabled(overrides == app.editorPreferences.overrides)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Monaco editor options as JSON, applied over the settings above, for example {\"cursorStyle\": \"block\"}. Keys like \"html.format.wrapLineLength\" set language options.")
            }
        }
        .formStyle(.grouped)
        .onAppear { overrides = app.editorPreferences.overrides }
    }

    private func applyOverrides() {
        guard let object = try? JSONSerialization.jsonObject(with: Data(overrides.utf8)), object is [String: Any] else {
            overridesError = "That isn't a JSON object."
            return
        }
        overridesError = nil
        var new = app.editorPreferences
        new.overrides = overrides
        try? app.setEditorPreferences(new)
    }

    /// Installed fixed-pitch font families, minus hidden system ones.
    private static let monospacedFamilies: [String] = Set(
        (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 12)?.familyName }
            .filter { !$0.hasPrefix(".") }
    ).sorted()
}

private struct FileSettingsTab: View {
    @Environment(AppModel.self) private var app
    @State private var newExtension = ""
    @State private var newLanguage = "plaintext"

    var body: some View {
        let pref = PreferencesBinding(app: app)
        Form {
            Section("Browsing") {
                Toggle("Open files and folders with a single click", isOn: pref(\.singleClickOpen))
            }
            Section {
                ForEach(app.editorPreferences.syntaxAssociations.sorted(by: { $0.key < $1.key }), id: \.key) { ext, lang in
                    LabeledContent(".\(ext)") {
                        HStack {
                            Text(MonacoCatalog.languageName(lang))
                            Button("Remove", systemImage: "minus.circle") { setAssociation(ext, nil) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Extension", text: $newExtension, prompt: Text("tpl"))
                        .frame(width: 90)
                    Picker("Language", selection: $newLanguage) {
                        Text("Plain Text").tag("plaintext")
                        ForEach(MonacoCatalog.languages) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Button("Add") {
                        setAssociation(newExtension, newLanguage)
                        newExtension = ""
                    }
                    .disabled(normalized(newExtension).isEmpty)
                }
            } header: {
                Text("Syntax Highlighting")
            } footer: {
                Text("Files with these extensions open with the language you pick, instead of the one Edith would choose.")
            }
        }
        .formStyle(.grouped)
    }

    private func normalized(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func setAssociation(_ ext: String, _ language: String?) {
        var new = app.editorPreferences
        new.syntaxAssociations[normalized(ext)] = language
        try? app.setEditorPreferences(new)
    }
}
