// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithEditor

/// Collects bridge events so a test can wait for one to arrive.
@MainActor
private final class EventLog {
    var events: [EditorEvent] = []

    init(_ bridge: EditorBridge) {
        bridge.onEvent = { [weak self] in self?.events.append($0) }
    }

    @discardableResult
    func wait(timeout: Duration = .seconds(20), for match: (EditorEvent) -> Bool) async throws -> EditorEvent {
        let deadline = ContinuousClock.now + timeout
        var seen = 0
        while ContinuousClock.now < deadline {
            if let hit = events[seen...].first(where: match) { return hit }
            seen = events.count
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out; events so far: \(events)")
        throw CancellationError()
    }

    var consoleMessages: [String] {
        events.compactMap { if case .console(let level, let message) = $0 { "\(level): \(message)" } else { nil } }
    }
}

@MainActor
@Suite(.serialized) struct EditorBridgeTests {
    @Test func editRoundTripThroughBridgeJS() async throws {
        let bridge = EditorBridge()
        let log = EventLog(bridge)

        // Queued before "ready", replayed after it, as in the Linux app.
        bridge.load("{\"a\": 1}\n", language: "json", configuration: .init())
        try await log.wait { $0 == .ready }
        try await log.wait { if case .initComplete(let eol, _) = $0 { eol == "lf" } else { false } }

        bridge.call("typeText", "x")
        try await log.wait { $0 == .modifiedChanged(true) }

        bridge.savePrepare(format: false)
        let saved = try await log.wait { if case .saveContent = $0 { true } else { false } }
        guard case .saveContent(let content) = saved else { return }
        #expect(content.contains("x"))

        bridge.markClean()
        try await log.wait { $0 == .modifiedChanged(false) }

        // Reloading keeps undo history (bridge.js's setContent), so the
        // edit is still undoable.
        bridge.setContent("{\"b\": 2}\n")
        try await Task.sleep(for: .milliseconds(200))
        let undoable = try await bridge.evaluate("monaco.editor.getModels()[0].canUndo()") as? Bool
        #expect(undoable == true)
    }

    /// Monaco's language features run in web workers started from a blob:
    /// URL that importScripts() from edith://. If that fails Monaco falls
    /// back to the main thread and says so on the console.
    @Test func languageWorkersStart() async throws {
        let bridge = EditorBridge()
        let log = EventLog(bridge)
        bridge.load("{\"a\": }\n", language: "json", configuration: .init())
        try await log.wait { if case .initComplete = $0 { true } else { false } }

        var markers = 0
        for _ in 0..<100 where markers == 0 {
            try await Task.sleep(for: .milliseconds(100))
            markers = try await bridge.evaluate("monaco.editor.getModelMarkers({}).length") as? Int ?? 0
        }
        #expect(markers > 0, "JSON validation produced no markers")
        let fallback = log.consoleMessages.filter { $0.contains("web worker") }
        #expect(fallback.isEmpty, "\(fallback)")
        print("console:", log.consoleMessages)
    }

    @Test func schemeHandlerStaysInsideMonacoTree() {
        let handler = MonacoSchemeHandler()
        #expect(handler.fileURL(for: URL(string: "edith://monaco/vs/loader.js")!) != nil)
        #expect(handler.fileURL(for: URL(string: "edith://monaco/../../../etc/passwd")!) == nil)
        #expect(handler.fileURL(for: URL(string: "edith://monaco/vs/%2E%2E/%2E%2E/%2E%2E/etc/passwd")!) == nil)
        #expect(handler.fileURL(for: URL(string: "edith://other/editor.html")!) == nil)
    }

    @Test func customOptionsPassThroughAsJSON() async throws {
        let bridge = EditorBridge()
        let log = EventLog(bridge)
        var config = EditorConfiguration()
        config.customOptionsJSON = #"{"cursorStyle": "block", "html.format.wrapLineLength": 0}"#
        bridge.load("x", language: "html", configuration: config)
        try await log.wait { if case .initComplete = $0 { true } else { false } }
        let style = try await bridge.evaluate("monaco.editor.getEditors()[0].getRawOptions().cursorStyle") as? String
        #expect(style == "block")

        var next = config
        next.settings.tabSize = 2
        next.theme = "monokai"
        bridge.apply(next, replacing: config)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await bridge.evaluate("monaco.editor.getModels()[0].getOptions().tabSize") as? Int == 2)
    }
}

@Test func languageDetection() {
    #expect(MonacoCatalog.language(forFileName: "index.PHP") == "php")
    #expect(MonacoCatalog.language(forFileName: "Dockerfile") == "dockerfile")
    #expect(MonacoCatalog.language(forFileName: "Makefile") == "shell")
    #expect(MonacoCatalog.language(forFileName: "notes") == "plaintext")
    #expect(MonacoCatalog.language(forFileName: "page.tpl", associations: ["tpl": "twig"]) == "twig")
    #expect(MonacoCatalog.languageName("javascript") == "JavaScript")
    #expect(MonacoCatalog.resolveTheme("", dark: true) == "vs-dark")
    #expect(MonacoCatalog.resolveTheme("nord", dark: false) == "nord")
}
