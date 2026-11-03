// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import SwiftUI

/// Add or edit a server: the fields of the Linux dialog, with the password or
/// passphrase kept in the Keychain.
struct ServerEditor: View {
    let request: ServerEditorRequest
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss

    @State private var server = Server()
    @State private var secret = ""
    @State private var originalSecret = ""
    @State private var portText = ""
    @State private var error: String?
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, succeeded, failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("Optional"))
                    Picker("Protocol", selection: $server.serverProtocol) {
                        Text("SFTP").tag(Server.ServerProtocol.sftp)
                        Text("FTP").tag(Server.ServerProtocol.ftp)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: server.serverProtocol) { _, new in adjustPort(for: new) }
                    TextField("Host", text: $server.host, prompt: Text("example.com"))
                    TextField("Port", text: $portText)
                    TextField("Username", text: $server.username)
                }

                Section {
                    if server.serverProtocol == .sftp {
                        Picker("Method", selection: $server.authMethod) {
                            Text("Password").tag(Server.AuthMethod.password)
                            Text("SSH Key").tag(Server.AuthMethod.key)
                            Text("SSH Key + Passphrase").tag(Server.AuthMethod.keyWithPassphrase)
                        }
                        if server.authMethod != .password {
                            LabeledContent("Key File") {
                                HStack {
                                    TextField("Key File", text: $server.keyFile, prompt: Text("~/.ssh/id_ed25519"))
                                        .labelsHidden()
                                    Button("Choose…", action: chooseKey)
                                }
                            }
                        }
                    } else {
                        Picker("Encryption", selection: $server.ftpEncryption) {
                            Text("None").tag(Server.FTPEncryption.none)
                            Text("Explicit TLS if Available").tag(Server.FTPEncryption.explicitOptional)
                            Text("Require Explicit TLS").tag(Server.FTPEncryption.explicitRequired)
                            Text("Implicit TLS").tag(Server.FTPEncryption.implicit)
                        }
                        .onChange(of: server.ftpEncryption) { _, new in adjustPort(for: new) }
                    }
                    if server.secretKind != .none {
                        SecureField(server.secretKind == .passphrase ? String(localized: "Passphrase") : String(localized: "Password"), text: $secret,
                                    prompt: Text("Ask when connecting"))
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    authFooter
                }

                Section("Options") {
                    TextField("Initial Directory", text: $server.initialDirectory, prompt: Text("/"))
                    Picker("Group", selection: $server.folderID) {
                        Text("No Group").tag("")
                        ForEach(app.folders) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Test Connection", action: test)
                    .disabled(!isValid || testState == .running)
                testResult
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? String(localized: "Add") : String(localized: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480)
        .navigationTitle(request.isNew ? String(localized: "Add Server") : String(localized: "Edit Server"))
        .onAppear(perform: load)
        .alert("Can't Save", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private var authFooter: some View {
        if server.serverProtocol == .ftp {
            Text("FTP uses passive mode. Without encryption, the password and files travel unprotected.")
        } else if server.secretKind != .none {
            Text("Saved in your Keychain. Leave empty to be asked when connecting.")
        } else if server.keyFile.isEmpty {
            Text("Without a key file, the keys in your SSH agent are tried.")
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red).help(message)
        }
    }

    private var isValid: Bool {
        !server.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !server.username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(portText).map { (1...65535).contains($0) } == true
    }

    private func load() {
        server = request.server
        portText = String(server.port)
        if !request.isNew { originalSecret = app.secret(for: server) ?? "" }
        secret = originalSecret
    }

    /// Switching protocol or TLS mode moves a default port to the new default.
    private func adjustPort(for _: some Any) {
        let defaults = ["22", "21", "990"]
        guard defaults.contains(portText) else { return }
        portText = server.serverProtocol == .sftp ? "22" : server.ftpEncryption == .implicit ? "990" : "21"
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose SSH Key")
        panel.showsHiddenFiles = true
        panel.directoryURL = URL.homeDirectory.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            server.keyFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func normalized() -> Server {
        var s = server
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.username = s.username.trimmingCharacters(in: .whitespaces)
        s.port = Int(portText) ?? s.port
        if s.initialDirectory.isEmpty { s.initialDirectory = "/" }
        return s
    }

    private func test() {
        let candidate = normalized()
        let typed = secret.isEmpty ? nil : secret
        testState = .running
        Task {
            do {
                let session = try await Session.connect(
                    to: candidate, secret: typed ?? app.secret(for: candidate),
                    hostKeys: app.hostKeys, certificates: app.certificates,
                    approveHostKey: { await Self.confirmHostKey($0) },
                    approveCertificate: { await Self.confirmCertificate($0) }
                )
                await session.close()
                testState = .succeeded
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    /// A sheet can't present another sheet, so testing asks with a plain alert.
    private static func confirmCertificate(_ challenge: CertificateChallenge) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Trust the certificate of \(challenge.host)?")
        alert.informativeText = CertificatePrompt.explanation(challenge) + "\n\n\(challenge.subject)\n\(challenge.fingerprint)"
        alert.addButton(withTitle: String(localized: "Trust"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmHostKey(_ challenge: HostKeyChallenge) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Trust \(challenge.host)?")
        alert.informativeText = HostKeyPrompt.explanation(challenge) + "\n\n\(challenge.keyType)\n\(challenge.fingerprint)"
        alert.addButton(withTitle: String(localized: "Trust"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func save() {
        do {
            let saved = normalized()
            try app.save(saved, secret: secret == originalSecret ? nil : secret)
            window.selectedServerIDs = [saved.id]
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Prompts

/// Password or passphrase, when none is saved or the saved one was rejected.
struct SecretPrompt: View {
    let request: SecretRequest
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var remember = true
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to \(request.server.displayName)").font(.headline)
            Text(verbatim: "Connecting as \(request.server.username)@\(request.server.host):\(request.server.port)")
                .foregroundStyle(.secondary)
            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField(request.kind == .passphrase ? String(localized: "Key Passphrase") : String(localized: "Password"), text: $secret)
                .textFieldStyle(.roundedBorder)
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { finish(secret) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear { if !answered { request.answer(nil, false) } }
    }

    private func finish(_ value: String?) {
        answered = true
        request.answer(value, remember)
        dismiss()
    }
}

/// The passphrase chosen when the servers were exported, to unlock their passwords.
struct PassphrasePrompt: View {
    let request: PassphraseRequest
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Saved Passwords").font(.headline)
            Text("This export includes passwords, encrypted with the passphrase chosen when it was exported. Enter it to save them to your Keychain.")
                .fixedSize(horizontal: false, vertical: true)
            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SecureField("Export Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { finish(passphrase) }
            HStack {
                Button("Skip Passwords") { finish(nil) }
                Spacer()
                Button("Import Passwords") { finish(passphrase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { if !answered { request.answer(nil) } }
    }

    private func finish(_ value: String?) {
        guard !answered else { return }
        answered = true
        request.answer(value)
        dismiss()
    }
}

/// An FTPS certificate macOS doesn't trust: show why and ask.
struct CertificatePrompt: View {
    let request: CertificateRequest
    @Environment(\.dismiss) private var dismiss
    @State private var answered = false

    static func explanation(_ c: CertificateChallenge) -> String {
        "macOS doesn't trust this server's certificate: \(c.reason) Hosting providers often use one certificate for all their customers, so a name mismatch can be harmless. If in doubt, compare the fingerprint with one from your provider."
    }

    var body: some View {
        let c = request.challenge
        VStack(alignment: .leading, spacing: 14) {
            Label("Untrusted Certificate", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.headline)
            Text(verbatim: "\(c.host):\(c.port)").font(.title3.monospaced())
            Text(Self.explanation(c))
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Issued to").foregroundStyle(.secondary); Text(c.subject) }
                    GridRow { Text("Issued by").foregroundStyle(.secondary); Text(c.issuer) }
                    GridRow {
                        Text("SHA-256").foregroundStyle(.secondary)
                        Text(c.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { finish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onDisappear { if !answered { request.answer(false) } }
    }

    private func finish(_ trust: Bool) {
        answered = true
        request.answer(trust)
        dismiss()
    }
}

/// An unknown host key: show its fingerprint and ask before trusting it.
struct HostKeyPrompt: View {
    let request: HostKeyRequest
    @Environment(\.dismiss) private var dismiss
    @State private var answered = false

    static func explanation(_ c: HostKeyChallenge) -> String {
        if c.otherKnownTypes.isEmpty {
            return "Edith hasn't connected to this server before and can't confirm its identity. That's normal the first time. If in doubt, compare the fingerprint with one from the server's administrator."
        }
        return "This server is on record with a different kind of key (\(c.otherKnownTypes.joined(separator: ", "))). It may have been reconfigured, or someone may be intercepting the connection. Only continue if you know why the key changed."
    }

    var body: some View {
        let c = request.challenge
        VStack(alignment: .leading, spacing: 14) {
            Label(c.otherKnownTypes.isEmpty ? String(localized: "Unknown Server") : String(localized: "Server Key Type Changed"),
                  systemImage: c.otherKnownTypes.isEmpty ? "questionmark.diamond" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(c.otherKnownTypes.isEmpty ? Color.primary : Color.orange)
            Text(KnownHosts.hostName(c.host, port: c.port)).font(.title3.monospaced())
            Text(Self.explanation(c))
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.keyType).foregroundStyle(.secondary)
                    Text(c.fingerprint).textSelection(.enabled)
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { finish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { if !answered { request.answer(false) } }
    }

    private func finish(_ trust: Bool) {
        answered = true
        request.answer(trust)
        dismiss()
    }
}

struct NamePrompt: View {
    let request: NameRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.headline)
            TextField(request.label, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.action, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = request.initial }
    }

    private func commit() {
        busy = true
        Task {
            do {
                try await request.commit(name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
