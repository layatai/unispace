import AppKit
import SwiftUI

@main
struct UniSpaceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("UniSpace", systemImage: model.isLocalController ? "cursorarrow.motionlines" : "display") {
            Text(model.statusMessage)
            Divider()
            if model.workspace != nil {
                Button("Make This Mac Controller") { model.makeThisMacController() }
                    .disabled(model.isLocalController)
                Button("Stop Remote Control") { model.stopControlling() }
            }
            SettingsLink { Text("Open UniSpace Settings…") }
            Divider()
            Button("Quit UniSpace") { NSApplication.shared.terminate(nil) }
        }

        Settings {
            SettingsRootView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}
