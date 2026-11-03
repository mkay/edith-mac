// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import SwiftUI

extension FocusedValues {
    @Entry var windowModel: WindowModel?
}

/// Menu bar commands. The Linux shortcuts, with ⌘ for Ctrl.
struct EdithCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Add Server…") { window?.addServer() }
                .keyboardShortcut("n")
                .disabled(window?.isDisconnected != true)
            Button("New Server Group…") { window?.newGroup() }
                .disabled(window?.isDisconnected != true)
            Divider()
            Button("Import Servers…") { window?.importServers() }
                .disabled(window == nil)
        }

        CommandMenu("Server") {
            Button("Connect") {
                if let window, let server = window.selectedServer { window.connect(server) }
            }
            .keyboardShortcut("o")
            .disabled(window?.selectedServer == nil || window?.isDisconnected != true)
            Button("Disconnect") { window?.disconnect() }
                .keyboardShortcut("d")
                .disabled(window?.connection == nil)
        }

        CommandMenu("Go") {
            let browser = window?.connection?.browser
            Button("Back") { Task { await browser?.goBack() } }
                .keyboardShortcut("[")
                .disabled(browser?.canGoBack != true)
            Button("Forward") { Task { await browser?.goForward() } }
                .keyboardShortcut("]")
                .disabled(browser?.canGoForward != true)
            Button("Enclosing Folder") { Task { await browser?.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(browser?.canGoUp != true)
            Divider()
            Button("Refresh") { window?.refresh() }
                .keyboardShortcut("r")
                .disabled(browser == nil)
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(window?.showFileDetails == true ? "Show Names Only" : "Show File Details") {
                window?.showFileDetails.toggle()
            }
            .disabled(window?.connection == nil)
        }
    }
}
