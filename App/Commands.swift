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

    private var editor: EditorController? { window?.connection?.editor }

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
            Button("Export Servers…") { window?.exportServers() }
                .disabled(window == nil)
        }

        CommandGroup(replacing: .help) {
            Button("What's New in Edith") { window?.showWhatsNew = true }
                .disabled(window == nil)
            Button("Support Edith…") { window?.showSupport = true }
                .disabled(window == nil)
            Divider()
            Link("Edith on GitHub", destination: URL(string: "https://github.com/mkay/edith")!)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await editor?.saveSelected() } }
                .keyboardShortcut("s")
                .disabled(editor?.selected == nil)
            Divider()
            Button("Close Tab") { Task { await editor?.closeSelected() } }
                .keyboardShortcut("w")
                .disabled(editor?.selected == nil)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { Task { await editor?.reopenClosed() } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(editor?.workspace.canReopenClosed != true)
        }

        CommandMenu("Editor") {
            let bridge = editor?.selected?.bridge
            Button("Find…") { bridge?.showFind() }
                .keyboardShortcut("f")
                .disabled(bridge == nil)
            Button("Find and Replace…") { bridge?.showReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(bridge == nil)
            Button("Go to Line…") { bridge?.gotoLine() }
                .keyboardShortcut("l")
                .disabled(bridge == nil)
            Divider()
            Button("Toggle Comment") { bridge?.toggleLineComment() }
                .keyboardShortcut("/")
                .disabled(bridge == nil)
            Button("Toggle Word Wrap") { bridge?.toggleWrap() }
                .keyboardShortcut("z", modifiers: .option)
                .disabled(bridge == nil)
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
