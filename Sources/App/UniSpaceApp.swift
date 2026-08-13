import AppKit
import SwiftUI

@main
struct UniSpaceApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("UniSpace", id: "main") {
            SettingsRootView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 820, height: 620)

        MenuBarExtra("UniSpace", systemImage: model.isLocalController ? "cursorarrow.motionlines" : "display") {
            Text(model.statusMessage)
            Divider()
            if model.workspace != nil {
                Button("Make This Mac Controller") { model.makeThisMacController() }
                    .disabled(model.isLocalController)
                Button("Stop Remote Control") { model.stopControlling() }
            }
            Button("Open UniSpace…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Divider()
            Button("Quit UniSpace") { NSApplication.shared.terminate(nil) }
        }
    }
}
