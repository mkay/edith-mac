// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithEditor
import SwiftUI

/// Phase 0 shell: an empty sidebar beside one Monaco editor, enough to see
/// the bridge working in a real window. Replaced in Phase 2.
struct ContentView: View {
    @State private var editor = EditorModel()

    var body: some View {
        NavigationSplitView {
            List {
                Text("No servers yet")
                    .foregroundStyle(.secondary)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                MonacoEditorView(bridge: editor.bridge)
                Divider()
                HStack {
                    Text(editor.modified ? "Modified" : "Saved")
                    Spacer()
                    Text("Ln \(editor.line), Col \(editor.column)")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .navigationTitle("sample.js")
        }
        .task { editor.start() }
    }
}

@MainActor
@Observable
final class EditorModel {
    let bridge = EditorBridge()
    var modified = false
    var line = 1
    var column = 1

    func start() {
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .modifiedChanged(let value): modified = value
            case .cursorChanged(let l, let c): (line, column) = (l, c)
            case .saveRequested: bridge.savePrepare(format: false)
            case .saveContent: bridge.markClean()
            case .initComplete: snapshotIfRequested()
            default: break
            }
        }
        bridge.initEditor(content: Self.sample, language: "javascript")
    }

    /// Debug hook for checking rendering from the command line:
    /// `open --env EDITH_SNAPSHOT=/path/out.png Edith.app` writes the editor's
    /// pixels after load. Launch it with `open`: WebKit skips painting a window
    /// that starts behind the terminal, and the snapshot comes out blank.
    private func snapshotIfRequested() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["EDITH_SNAPSHOT"] else { return }
        Task {
            do {
                try await Task.sleep(for: .seconds(1))
                let image = try await bridge.webView.takeSnapshot(configuration: nil)
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return }
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                print("snapshot failed: \(error)")
            }
        }
        #endif
    }

    private static let sample = """
    // Edith for macOS: Phase 0 editor spike.
    // Edit and press Cmd-S: the status bar goes from Modified back to Saved.

    function greet(name) {
      return `Hello, ${name}!`;
    }

    console.log(greet("Edith"));
    """
}
