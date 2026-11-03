// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import SwiftUI

/// The sidebar while connected: actions, filter, the folder dropdown, the
/// file list, pinned files and the connection status.
struct FileSidebar: View {
    let connection: Connection
    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var browser = connection.browser
        @Bindable var window = window
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Upload", systemImage: "square.and.arrow.up") { window.chooseUploads() }
                    .help("Upload files or folders here")
                Button("Refresh", systemImage: "arrow.clockwise") { window.refresh() }
                    .help("Refresh (⌘R)")
                Toggle("Show Hidden Files", systemImage: browser.showHidden ? "eye" : "eye.slash", isOn: $browser.showHidden)
                    .help(browser.showHidden ? "Hide hidden files" : "Show hidden files")
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Toggle("Details", systemImage: "list.bullet.rectangle", isOn: $window.showFileDetails)
                    .help(window.showFileDetails ? "Show names only" : "Show size, date, permissions and owner")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            VStack(spacing: 6) {
                TextField("Filter files", text: $browser.filter, prompt: Text("Filter files…"))
                    .textFieldStyle(.roundedBorder)
                AncestorMenu(browser: browser, path: browser.path)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            FileTable(
                connection: connection,
                entries: browser.visible,
                path: browser.path,
                showDetails: window.showFileDetails,
                sortKey: browser.sortKey,
                ascending: browser.ascending
            )
            .overlay { overlay(browser) }

            if !connection.pins.isEmpty {
                PinnedFiles(connection: connection)
            }
            StatusLine(
                text: statusText,
                systemImage: "bolt.horizontal.circle.fill",
                active: true
            )
        }
    }

    private var statusText: String {
        if let job = connection.transfers.active {
            if case .running(let fraction?) = job.state { return "\(job.label) — \(Int(fraction * 100))%" }
            return job.label
        }
        let s = connection.server
        return "Connected to \(s.username)@\(s.host)"
    }

    @ViewBuilder private func overlay(_ browser: Browser) -> some View {
        if let error = browser.error {
            ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
                .allowsHitTesting(false)
        } else if browser.visible.isEmpty && !browser.isLoading {
            Text(browser.filter.isEmpty ? "Empty folder" : "No matches")
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
    }
}

/// The current folder's name; opens to jump to any folder above it.
///
/// An NSPopUpButton, because SwiftUI's menu picker sizes itself to its
/// contents and won't fill the sidebar's width.
struct AncestorMenu: NSViewRepresentable {
    let browser: Browser
    /// Passed in, not read from `browser`, so SwiftUI updates on navigation.
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.chosen(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.browser = browser
        guard button.toolTip != path else { return }
        button.removeAllItems()
        for ancestor in remoteAncestors(path) {
            let item = NSMenuItem(title: remoteName(ancestor), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: ancestor == "/" ? "externaldrive" : "folder", accessibilityDescription: nil)
            item.representedObject = ancestor
            button.menu?.addItem(item)
        }
        button.selectItem(at: 0)
        button.toolTip = path
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var browser: Browser?

        @objc func chosen(_ sender: NSPopUpButton) {
            guard let path = sender.selectedItem?.representedObject as? String, let browser, path != browser.path else { return }
            Task { await browser.open(path) }
        }
    }
}

struct PinnedFiles: View {
    let connection: Connection
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("Pinned")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(connection.pins, id: \.path) { pin in
                Button {
                    window.activate(pin)
                } label: {
                    Label(remoteName(pin.path), systemImage: pin.isDirectory ? "folder" : "doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .help(pin.path)
                .contextMenu {
                    Button("Unpin") { window.unpin(pin) }
                }
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Toolbar

/// Breadcrumbs for the current path. Each part opens that folder.
struct PathBar: View {
    let browser: Browser

    var body: some View {
        let parts = Array(remoteAncestors(browser.path).reversed())
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.element) { index, path in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
                Button {
                    Task { await browser.open(path) }
                } label: {
                    if path == "/" {
                        Image(systemName: "externaldrive").accessibilityLabel("Root")
                    } else {
                        Text(remoteName(path))
                            .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxWidth: 560)
    }
}

/// Shows progress while busy; opens the transfer list.
struct TransferButton: View {
    let log: TransferLog
    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        Button {
            window.showTransfers.toggle()
        } label: {
            if case .running(let fraction?) = log.active?.state {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
            } else {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
            }
        }
        .help("Transfers")
        .disabled(log.jobs.isEmpty)
        .popover(isPresented: $window.showTransfers, arrowEdge: .bottom) {
            TransferPanel(log: log)
        }
    }
}

struct TransferPanel: View {
    let log: TransferLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { log.clearFinished() }
                    .disabled(!log.hasFinished)
            }
            .padding(12)
            Divider()
            if log.jobs.isEmpty {
                Text("No transfers").foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(log.jobs.reversed()) { job in
                            TransferRow(job: job) { log.cancel(job.id) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }
}

private struct TransferRow: View {
    let job: TransferLog.Job
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.label).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .running(let fraction): ProgressView(value: fraction ?? 0).progressViewStyle(.linear)
                case .done: Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if !job.isFinished {
                Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Main area

/// Where the editor goes in Phase 3.
struct ConnectedDetail: View {
    let connection: Connection

    var body: some View {
        ContentUnavailableView {
            Label("Connected to \(connection.server.host)", systemImage: "checkmark.circle")
        } description: {
            Text("Browse files in the sidebar. Editing arrives in the next version of the Mac app.")
        }
    }
}
