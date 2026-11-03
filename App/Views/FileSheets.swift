// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import SwiftUI

/// Information about a file, with its permissions editable as in the Linux
/// app's Information dialog.
struct FileInfoSheet: View {
    let file: RemoteFile
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @State private var permissions: UInt32 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: FileIcons.icon(for: file)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(file.name).font(.headline).lineLimit(2)
                    Text(file.isDirectory ? "Folder" : file.size.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Path", file.path)
                if file.isSymlink { row("Kind", file.isDirectory ? String(localized: "Link to a folder") : String(localized: "Link")) }
                if !file.isDirectory { row("Size", "\(file.size.formatted()) bytes") }
                row("Modified", file.modified?.formatted(date: .long, time: .standard) ?? "—")
                row("Owner", file.owner.isEmpty ? "—" : file.owner)
                row("Group", file.group.isEmpty ? "—" : file.group)
            }

            GroupBox("Permissions") {
                Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Read").font(.caption).foregroundStyle(.secondary)
                        Text("Write").font(.caption).foregroundStyle(.secondary)
                        Text("Execute").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach([("Owner", UInt32(6)), ("Group", UInt32(3)), ("Others", UInt32(0))], id: \.0) { name, shift in
                        GridRow {
                            Text(name).gridColumnAlignment(.leading)
                            ForEach([UInt32(4), 2, 1], id: \.self) { bit in
                                Toggle(name, isOn: binding(bit << shift)).labelsHidden()
                            }
                        }
                    }
                }
                .padding(6)
                HStack {
                    Text(String(format: "%04o", permissions)).font(.body.monospaced())
                    Text(RemoteFile(name: "", path: "", mode: file.mode & ~0o7777 | permissions).permissionsString)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    window.setPermissions(file, to: permissions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(permissions == file.permissions)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { permissions = file.permissions }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private func binding(_ bit: UInt32) -> Binding<Bool> {
        Binding(
            get: { permissions & bit != 0 },
            set: { permissions = $0 ? permissions | bit : permissions & ~bit }
        )
    }
}

/// Picks a folder on the server, for Move to and Copy to.
struct FolderChooser: View {
    let choice: FolderChoice
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @State private var path = "/"
    @State private var folders: [RemoteFile] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choice.title).font(.headline)
            HStack {
                Button("Up", systemImage: "arrow.up") { load(remoteParent(path)) }
                    .labelStyle(.iconOnly)
                    .disabled(path == "/")
                Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            List(folders) { folder in
                Label(folder.name, systemImage: "folder")
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { load(folder.path) }
            }
            .listStyle(.bordered)
            .overlay {
                if let error { Text(error).foregroundStyle(.secondary).padding() }
                else if folders.isEmpty && !loading { Text("No folders").foregroundStyle(.secondary) }
            }
            Text("Double-click a folder to open it.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(choice.action) Here") {
                    let target = path
                    dismiss()
                    Task { await choice.choose(target) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .onAppear { load(choice.start) }
    }

    private func load(_ newPath: String) {
        guard let client = window.connection?.session.client else { return }
        path = newPath
        loading = true
        Task {
            do {
                folders = try await client.list(newPath)
                    .filter(\.isDirectory)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                error = nil
            } catch {
                folders = []
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
