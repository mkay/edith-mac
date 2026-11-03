// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import WebKit

/// What bridge.js reports through `window.webkit.messageHandlers.edith`.
public enum EditorEvent: Equatable, Sendable {
    case ready
    case initComplete(lineEnding: String, wordWrap: Bool)
    case cursorChanged(line: Int, column: Int)
    case modifiedChanged(Bool)
    case wrapChanged(Bool)
    case saveRequested
    case saveContent(String)
    case contentSnapshot(String)
    case closeRequested
    case historyReset(reason: String)
    /// The web content process died. Undo history is gone; the last
    /// `contentSnapshot` is what can still be recovered.
    case processTerminated
    case console(level: String, message: String)
}

/// Settings passed to `EdithBridge.init`, mirroring the Linux app's dict.
public struct EditorSettings: Encodable, Sendable {
    public var insertSpaces = true
    public var tabSize = 4
    public var minimap = false
    public var renderWhitespace = "selection"
    public var stickyScroll = false
    public var fontLigatures = false
    public var lineNumbers = "on"

    public init() {}
}

/// One Monaco instance in a WKWebView, and the JS bridge to it.
///
/// The Swift counterpart of the Linux app's MonacoEditor widget: calls made
/// before bridge.js says "ready" are queued and replayed, and every message
/// from JS arrives as an `EditorEvent` on `onEvent`.
@MainActor
public final class EditorBridge {
    public let webView: WKWebView
    public var onEvent: ((EditorEvent) -> Void)?
    public private(set) var isReady = false

    private var pending: [String] = []
    private let messageProxy = MessageProxy()
    private let navigationProxy = NavigationProxy()
    private static let log = Logger(subsystem: "de.singular.edith", category: "editor")

    public init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MonacoSchemeHandler(), forURLScheme: MonacoSchemeHandler.scheme)

        let content = config.userContentController
        content.add(messageProxy, name: "edith")
        content.add(messageProxy, name: "console")
        content.addUserScript(WKUserScript(source: Self.consoleForwarder, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = navigationProxy

        messageProxy.bridge = self
        navigationProxy.bridge = self
        webView.load(URLRequest(url: MonacoSchemeHandler.editorURL))
    }

    // MARK: Calls into EdithBridge

    /// Calls `EdithBridge.<function>(args…)`, queued until the editor is ready.
    public func call(_ function: String, _ args: any Encodable...) {
        let encoder = JSONEncoder()
        let json = args.map { arg in
            (try? encoder.encode(arg)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        run("EdithBridge.\(function)(\(json.joined(separator: ", ")))")
    }

    public func initEditor(
        content: String,
        language: String,
        theme: String = "vs-dark",
        fontFamily: String = "SF Mono, Menlo, monospace",
        fontSize: Int = 13,
        wordWrap: Bool = true,
        settings: EditorSettings = .init(),
        customOptions: [String: String] = [:]
    ) {
        call("init", content, language, theme, fontFamily, fontSize, wordWrap, settings, customOptions)
    }

    /// Asks for the buffer; it arrives as `.saveContent`.
    public func savePrepare(format: Bool) { call("savePrepare", format) }
    public func markClean() { call("markClean") }
    public func setContent(_ content: String) { call("setContent", content) }

    /// Evaluates arbitrary JS once ready. For tests and diagnostics.
    public func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    private func run(_ script: String) {
        guard isReady else {
            pending.append(script)
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error { Self.log.error("JS call failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Messages from JS

    fileprivate func receive(name: String, body: Any) {
        if name == "console", let dict = body as? [String: Any] {
            emit(.console(level: dict["level"] as? String ?? "log", message: dict["message"] as? String ?? ""))
            return
        }
        guard let text = body as? String,
              let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = msg["type"] as? String
        else { return }
        let data = msg["data"] as? [String: Any] ?? [:]

        switch type {
        case "ready":
            isReady = true
            let queued = pending
            pending = []
            emit(.ready)
            queued.forEach(run)
        case "init-complete":
            emit(.initComplete(lineEnding: data["lineEnding"] as? String ?? "lf", wordWrap: data["wordWrap"] as? Bool ?? true))
        case "cursor-changed":
            emit(.cursorChanged(line: data["line"] as? Int ?? 1, column: data["column"] as? Int ?? 1))
        case "modified-changed":
            emit(.modifiedChanged(data["modified"] as? Bool ?? false))
        case "wrap-changed":
            emit(.wrapChanged(data["wordWrap"] as? Bool ?? true))
        case "save-requested":
            emit(.saveRequested)
        case "save-content":
            emit(.saveContent(data["content"] as? String ?? ""))
        case "content-snapshot":
            emit(.contentSnapshot(data["content"] as? String ?? ""))
        case "close-requested":
            emit(.closeRequested)
        case "history-reset":
            emit(.historyReset(reason: data["reason"] as? String ?? "unknown"))
        default:
            Self.log.debug("unhandled bridge message \(type, privacy: .public)")
        }
    }

    fileprivate func processTerminated() {
        isReady = false
        pending = []
        emit(.processTerminated)
    }

    private func emit(_ event: EditorEvent) {
        onEvent?(event)
    }

    /// Mirrors console output to Swift, so Monaco's warnings (a worker that
    /// failed to start, say) show up in the log rather than only in the
    /// inspector.
    private static let consoleForwarder = """
    (function () {
      ["log", "info", "warn", "error"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try {
            var parts = Array.prototype.map.call(arguments, function (a) {
              return (a && a.stack) ? String(a.stack) : (typeof a === "object" ? JSON.stringify(a) : String(a));
            });
            window.webkit.messageHandlers.console.postMessage({ level: level, message: parts.join(" ") });
          } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.addEventListener("error", function (e) {
        window.webkit.messageHandlers.console.postMessage({ level: "error", message: String(e.message) });
      });
    })();
    """
}

/// WKUserContentController retains its handlers; this keeps it from
/// retaining the bridge (and with it the web view) in a cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: EditorBridge?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            bridge?.receive(name: message.name, body: message.body)
        }
    }
}

private final class NavigationProxy: NSObject, WKNavigationDelegate {
    weak var bridge: EditorBridge?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            bridge?.processTerminated()
        }
    }
}
