// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JavaScriptCore

/// Minifies JavaScript with terser and CSS with csso, run in JavaScriptCore:
/// no web view, no DOM. The bundles sit beside Monaco, from fetch-monaco.sh.
public actor Minifier {
    public enum Kind: Sendable {
        case javaScript, css

        /// The kind for a file name, or nil if it's neither.
        public init?(fileName: String) {
            switch (fileName as NSString).pathExtension.lowercased() {
            case "js", "mjs", "cjs": self = .javaScript
            case "css": self = .css
            default: return nil
            }
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { "Couldn't minify: \(message)" }
    }

    public static let shared = Minifier()
    private var context: JSContext?

    /// `stem.min.ext` for `stem.ext`, even if the name already ends in .min:
    /// the source is never overwritten.
    public nonisolated static func outputName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        return "\((fileName as NSString).deletingPathExtension).min.\(ext)"
    }

    public func minify(_ code: String, kind: Kind) throws -> String {
        let js = try loadedContext()
        js.exception = nil
        js.setObject(code, forKeyedSubscript: "__edith_input" as NSString)
        js.evaluateScript(kind == .javaScript ? "__edith_minify_js(__edith_input)" : "__edith_minify_css(__edith_input)")
        if let exception = js.exception { throw Failure(message: exception.toString()) }
        // terser answers with a promise; JavaScriptCore runs its callbacks
        // before evaluateScript returns, so the result is already there.
        if let error = js.objectForKeyedSubscript("__edith_error"), !error.isNull, !error.isUndefined {
            throw Failure(message: error.toString())
        }
        guard let result = js.objectForKeyedSubscript("__edith_result"), result.isString else {
            throw Failure(message: "no result")
        }
        return result.toString()
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        guard let js = JSContext() else { throw Failure(message: "JavaScriptCore is unavailable") }
        let dir = MonacoSchemeHandler.bundledRoot
        for name in ["terser.js", "csso.js"] {
            let source = try String(contentsOf: dir.appending(path: name), encoding: .utf8)
            js.evaluateScript(source)
            if let exception = js.exception { throw Failure(message: "\(name): \(exception)") }
        }
        js.evaluateScript("""
        var __edith_result = null, __edith_error = null;
        function __edith_minify_js(code) {
            __edith_result = null; __edith_error = null;
            Terser.minify(code, {}).then(
                function (r) { __edith_result = r.code; },
                function (e) { __edith_error = String(e); });
        }
        function __edith_minify_css(code) {
            __edith_result = null; __edith_error = null;
            try { __edith_result = csso.minify(code).css; }
            catch (e) { __edith_error = String(e); }
        }
        """)
        context = js
        return js
    }
}
