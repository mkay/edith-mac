// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore

/// Asks before quitting with unsaved changes, and clears temp files after.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let unsaved = app?.unsavedSummary, !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit with Unsaved Changes?")
        alert.informativeText = String(localized: "Unsaved changes in:\n") + unsaved.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Discard and Quit")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.shared.cleanup()
    }
}

/// Sits in front of SwiftUI's window delegate to answer windowShouldClose,
/// which SwiftUI has no API for, and passes everything else through.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: (any NSWindowDelegate)?
    private let shouldClose: () -> Bool

    init(window: NSWindow, shouldClose: @escaping () -> Bool) {
        self.original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}
