// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import EdithCore
import SwiftUI

@main
struct EdithApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .frame(minWidth: 760, minHeight: 460)
                .environment(app)
                .task { delegate.app = app }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { EdithCommands() }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
