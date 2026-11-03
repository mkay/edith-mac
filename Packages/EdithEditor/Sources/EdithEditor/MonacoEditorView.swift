// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import WebKit

/// Hosts an `EditorBridge`'s web view in SwiftUI. The bridge outlives view
/// updates, so the owner (one per editor tab) keeps it, not this view.
public struct MonacoEditorView: NSViewRepresentable {
    let bridge: EditorBridge

    public init(bridge: EditorBridge) {
        self.bridge = bridge
    }

    public func makeNSView(context: Context) -> WKWebView {
        bridge.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
