import AppKit
import SwiftUI

@main
struct UniSpaceApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("UniSpace", id: "main") {
            SettingsRootView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { model.refreshPermissions() }
        }
        .defaultSize(width: 900, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Make This Mac Controller") { model.makeThisMacController() }
                    .disabled(model.workspace == nil || model.isLocalController)
                Button("Stop Remote Control") { model.stopControlling() }
                    .keyboardShortcut(.escape, modifiers: [.control, .option, .command])
                    .disabled(model.workspace == nil)
            }
        }

        MenuBarExtra {
            menuContent
        } label: {
            Image(systemName: model.isLocalController ? "cursorarrow.motionlines" : "display")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(model.workspace?.name ?? "UniSpace")
        Text(model.statusMessage)

        Divider()

        if model.workspace != nil {
            Button("Make This Mac Controller") { model.makeThisMacController() }
                .disabled(model.isLocalController)
            Button("Stop Remote Control") { model.stopControlling() }

            if model.needsPermissions {
                Divider()
                Text("Permissions needed")
            }
        }

        Divider()

        Button("Open UniSpace…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit UniSpace") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
