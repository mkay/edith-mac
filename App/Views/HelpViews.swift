// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The passphrase that protects passwords in an export, entered twice.
struct NewPassphrasePrompt: View {
    let request: PassphraseRequest
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var repeated = ""
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Protect the Passwords").font(.headline)
            Text("Choose a passphrase. You'll need it to import the passwords, on this Mac or in the Linux app. There's no way to recover them without it.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
            SecureField("Repeat Passphrase", text: $repeated)
            if !repeated.isEmpty && repeated != passphrase {
                Text("The passphrases don't match.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { finish(passphrase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.count < 8 || passphrase != repeated)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 400)
        .onDisappear { if !answered { request.answer(nil) } }
    }

    private func finish(_ value: String?) {
        answered = true
        request.answer(value)
        dismiss()
    }
}

/// Help ▸ Support Edith: the Linux app's "Keep this app alive".
struct SupportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep this app alive").font(.title2.weight(.semibold))
            Text("This app doesn't track. Anything.\nThe downside is I have no idea if or how often it's used or downloaded. Could be zero, could be a secret cult following. I genuinely don't know.")
            Text("Am I wasting my time publishing it? You tell me.")
            Text("There are three (maybe more) ways to keep me motivated:")
            way("The easy way", "Give it a like", "heart",
                "Opens a page on my website with a like button. Nothing is counted until you press it — just the press and an anonymised IP.",
                "https://singular.de/apps/feedback/?edith", prominent: true)
            way("The nerdy way", "Star it on GitHub", "star",
                "A star is a number I can actually see, and it helps others find it.",
                "https://github.com/mkay/edith")
            way("The generous way", "Support it on Ko-fi", "cup.and.saucer",
                "Entirely optional. Edith is and stays free either way.",
                "https://ko-fi.com/s1ngular")
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }

    private func way(_ title: String, _ action: String, _ icon: String, _ note: String, _ url: String, prominent: Bool = false) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: url)!) { Label(action, systemImage: icon) }
                    .buttonStyle(.borderedProminent)
                    .tint(prominent ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// Help ▸ What's New, and once after each update.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// The bullets of whatsnew.md: one per line outside the comment.
    static var notes: [AttributedString] {
        guard let url = Bundle.main.url(forResource: "whatsnew", withExtension: "md"),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        while let start = text.range(of: "<!--"), let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let bullet = line.first.map { "-*•".contains($0) } == true ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
                return (try? AttributedString(markdown: bullet)) ?? AttributedString(bullet)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New in Edith \(Self.version)").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
