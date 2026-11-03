// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled Monaco tree at `edith://monaco/…`.
///
/// A custom scheme instead of file:// gives the editor a real origin, so the
/// AMD loader, its web workers and fetch() all behave as they would over
/// HTTP, without the file-URL permission switches the Linux app needs.
final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "edith"
    static let host = "monaco"
    static let editorURL = URL(string: "\(scheme)://\(host)/editor.html")!

    let root: URL

    init(root: URL = MonacoSchemeHandler.bundledRoot) {
        self.root = root.standardizedFileURL
    }

    static var bundledRoot: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Monaco", isDirectory: true)
    }

    /// The file a request URL maps to, or nil if it is outside the Monaco tree.
    func fileURL(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host == Self.host else { return nil }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = fileURL(for: url),
              let data = try? Data(contentsOf: file)
        else {
            let response = HTTPURLResponse(url: task.request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            // Monaco's workers start from a blob: URL and importScripts() from here.
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
