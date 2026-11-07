// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EdithCore
import SwiftUI

extension View {
    /// Debug builds only: drive the window from the environment, for
    /// checking the UI from the command line.
    ///
    /// - `EDITH_AUTOCONNECT=<server name>` connects on launch.
    /// - `EDITH_SHOW_DETAILS=1` turns on the file details columns.
    /// - `EDITH_OPEN=a.php,b.css` opens those files (relative to the start
    ///   directory) after connecting.
    /// - `EDITH_WINDOW_WIDTH=<points>` resizes the window before the snapshot,
    ///   by `EDITH_WINDOW_STEP` points at a time if that's set.
    /// - `EDITH_SNAPSHOT=/path/out.png` saves the window after
    ///   `EDITH_SNAPSHOT_DELAY` seconds (default 3), then quits.
    ///
    /// Launch with `open --env …`: a window started behind the terminal
    /// isn't drawn, and the snapshot comes out blank.
    func debugHooks(_ window: WindowModel) -> some View {
        #if DEBUG
        modifier(DebugHooks(window: window))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugHooks: ViewModifier {
    let window: WindowModel
    @State private var webProbe = ""

    func body(content: Content) -> some View {
        content.task {
            let env = ProcessInfo.processInfo.environment
            if let name = env["EDITH_AUTOCONNECT"],
               let server = window.app.servers.first(where: { $0.displayName == name }) {
                window.selectedServerIDs = [server.id]
                window.connect(server)
            }
            if env["EDITH_SHOW_DETAILS"] == "1" { window.showFileDetails = true }
            if let files = env["EDITH_OPEN"] {
                for _ in 0..<100 where window.connection == nil { try? await Task.sleep(for: .milliseconds(100)) }
                if let start = window.connection?.session.startDirectory {
                    for name in files.split(separator: ",") {
                        window.openFile(at: remoteJoin(start, String(name)))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
            // EDITH_TYPE=text types into the open tab, then saves it.
            if let text = env["EDITH_TYPE"], let editor = window.connection?.editor {
                try? await Task.sleep(for: .seconds(1))
                if let tab = editor.selected {
                    tab.bridge?.call("typeText", text)
                    try? await Task.sleep(for: .milliseconds(300))
                    await editor.save(tab)
                }
            }
            guard let path = env["EDITH_SNAPSHOT"] else { return }
            let delay = Double(env["EDITH_SNAPSHOT_DELAY"] ?? "") ?? 3
            try? await Task.sleep(for: .seconds(delay))
            if let width = Double(env["EDITH_WINDOW_WIDTH"] ?? ""), let host = window.hostWindow {
                // In steps, as a drag would, unless EDITH_WINDOW_STEP is 0.
                let step = Double(env["EDITH_WINDOW_STEP"] ?? "") ?? 0
                var current = host.contentLayoutRect.width
                while step > 0, abs(current - width) > step {
                    current += current < width ? step : -step
                    host.setContentSize(NSSize(width: current, height: host.contentLayoutRect.height))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                host.setContentSize(NSSize(width: width, height: host.contentLayoutRect.height))
                try? await Task.sleep(for: .seconds(1))
            }
            if let bridge = window.connection?.editor.selected?.bridge {
                let js = "JSON.stringify({w: innerWidth, h: innerHeight, layout: monaco.editor.getEditors()[0].getLayoutInfo().width, lines: monaco.editor.getModels()[0].getLineCount(), visible: document.visibilityState})"
                webProbe = "webview frame \(bridge.webView.frame) in window: \(bridge.webView.window != nil) hidden: \(bridge.webView.isHiddenOrHasHiddenAncestor) js: \((try? await bridge.evaluate(js)) as? String ?? "-")"
            }
            snapshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Draws each visible window, toolbar included, into a PNG: the main
    /// window to `url`, sheets and popovers to `url` with -1, -2… added.
    private func snapshot(to url: URL) {
        let windows = NSApp.windows.filter(\.isVisible).sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        var outline = ""
        for (index, window) in windows.enumerated() {
            let target = index == 0 ? url : URL(fileURLWithPath: "\(url.deletingPathExtension().path)-\(index).png")
            if let frame = window.contentView?.superview, let layer = frame.layer {
                // Rendering the layer tree draws what cacheDisplay leaves
                // white: the glass of the sidebar and toolbar.
                let scale = window.backingScaleFactor
                let size = CGSize(width: frame.bounds.width * scale, height: frame.bounds.height * scale)
                if let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.scaleBy(x: scale, y: scale)
                    if !frame.isFlipped {
                        // layer.render draws top-down already for unflipped AppKit layers.
                    }
                    layer.render(in: context)
                    if let image = context.makeImage() {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: target)
                    }
                }
            }
            outline += "== \(target.lastPathComponent): \(window.title)\n"
            describe(window, depth: 0, into: &outline)
        }
        // Glass (sidebar, toolbar) can't be captured from inside the app,
        // so the window's state goes alongside as text.
        outline = stateDescription() + "\n" + webProbe + "\n" + outline
        try? outline.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    private func stateDescription() -> String {
        var lines: [String] = []
        if let toolbar = window.hostWindow?.toolbar {
            let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
            lines.append("detail width: \(window.detailWidth)")
            lines.append("toolbar:")
            for item in toolbar.items {
                let frame = item.view?.frame ?? .zero
                lines.append("  \(item.itemIdentifier.rawValue) priority:\(item.visibilityPriority.rawValue) visible:\(visible.contains(item.itemIdentifier)) \(item.label) width:\(frame.width) x:\(frame.minX)")
            }
        }
        switch window.phase {
        case .disconnected: lines.append("phase: disconnected, selected: \(window.selectedServerIDs.sorted())")
        case .connecting(let s): lines.append("phase: connecting to \(s.displayName)")
        case .connected(let c):
            let b = c.browser
            lines.append("phase: connected to \(c.server.displayName), home \(c.session.home), canExec \(c.session.canExec)")
            lines.append("path: \(b.path) back:\(b.canGoBack) forward:\(b.canGoForward) loading:\(b.isLoading) error:\(b.error ?? "-")")
            lines.append("sort: \(b.sortKey) \(b.ascending ? "asc" : "desc"), hidden:\(b.showHidden), filter:“\(b.filter)”, details:\(window.showFileDetails)")
            for f in b.visible {
                lines.append("  \(f.isDirectory ? "d" : "-") \(f.name)  \(f.size)  \(f.permissionsString)  \(f.owner)")
            }
            lines.append("pins: \(c.pins.map(\.path))")
            lines.append("recents: \(c.recents)")
            for tab in c.editor.orderedTabs {
                let d = tab.document
                lines.append("tab\(tab === c.editor.selected ? "*" : " ") \(d.name) kind:\(d.kind) modified:\(d.isModified) deleted:\(d.isDeleted) lang:\(tab.language) eol:\(tab.lineEnding) wrap:\(tab.wordWrap) enc:\(d.encoding.rawValue) ln:\(tab.line)")
            }
            lines.append("transfers: \(c.transfers.jobs.map { "\($0.label)=\($0.state)" })")
        }
        if let r = window.hostKeyRequest { lines.append("PROMPT host key: \(r.challenge.keyType) \(r.challenge.fingerprint) others:\(r.challenge.otherKnownTypes)") }
        if let r = window.secretRequest { lines.append("PROMPT secret for \(r.server.displayName): \(r.kind) error:\(r.error ?? "-")") }
        if let m = window.message { lines.append("ALERT \(m.title): \(m.text)") }
        if let c = window.confirmation { lines.append("CONFIRM \(c.title): \(c.message)") }
        if let n = window.nameRequest { lines.append("PROMPT name: \(n.title)") }
        if let c = window.choice { lines.append("CHOICE \(c.title): \(c.options.map(\.title))") }
        lines.append("menus:")
        for item in NSApp.mainMenu?.items ?? [] {
            let entries = item.submenu?.items.filter { !$0.isSeparatorItem }.map { i in
                i.keyEquivalent.isEmpty ? i.title : "\(i.title) [\(Self.shortcut(i))]"
            } ?? []
            lines.append("  \(item.title): \(entries.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        var s = ""
        if item.keyEquivalentModifierMask.contains(.control) { s += "⌃" }
        if item.keyEquivalentModifierMask.contains(.option) { s += "⌥" }
        if item.keyEquivalentModifierMask.contains(.shift) { s += "⇧" }
        if item.keyEquivalentModifierMask.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent.uppercased()
    }

    private func describe(_ element: Any, depth: Int, into out: inout String) {
        guard depth < 40, let e = element as? NSAccessibilityProtocol else { return }
        let role = e.accessibilityRole()?.rawValue.replacingOccurrences(of: "AX", with: "") ?? "?"
        let texts = [e.accessibilityLabel(), e.accessibilityTitle(), e.accessibilityValue() as? String, e.accessibilityHelp()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let enabled = e.isAccessibilityEnabled() == false ? " [disabled]" : ""
        let boring = ["Group", "SplitGroup", "ScrollArea", "LayoutArea", "Unknown"].contains(role) && texts.isEmpty
        if !boring {
            out += String(repeating: "  ", count: depth) + role + (texts.isEmpty ? "" : " " + texts.map { "“\($0)”" }.joined(separator: " ")) + enabled + "\n"
        }
        for child in e.accessibilityChildren() ?? [] {
            describe(child, depth: boring ? depth : depth + 1, into: &out)
        }
    }
}
#endif
