import AppKit
import SwiftUI

@main
struct UniSpaceApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var transferModel = FileTransferViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("UniSpace", id: "main") {
            SettingsRootView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear {
                    DockIconVisibility.show()
                    model.refreshPermissions()
                    transferModel.bind(to: model)
                }
                .onDisappear { DockIconVisibility.hideWhenNoVisibleWindows() }
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
                Divider()
                Button("File Transfers…") { openTransferCenter() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.workspace == nil)
            }
        }

        Window("UniSpace Transfers", id: "transfers") {
            TransferCenterView(model: transferModel)
                .frame(minWidth: 680, minHeight: 480)
                .onAppear {
                    DockIconVisibility.show()
                    transferModel.bind(to: model)
                }
                .onDisappear { DockIconVisibility.hideWhenNoVisibleWindows() }
        }
        .defaultSize(width: 760, height: 560)
        .windowToolbarStyle(.unified)

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
            Button {
                openTransferCenter()
            } label: {
                if transferModel.activeTransferCount > 0 {
                    Text("File Transfers (\(transferModel.activeTransferCount))…")
                } else {
                    Text("File Transfers…")
                }
            }

            if model.needsPermissions {
                Divider()
                Text("Permissions needed")
            }
        }

        Divider()

        Button("Open UniSpace…") {
            DockIconVisibility.show()
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit UniSpace") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openTransferCenter() {
        DockIconVisibility.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
        transferModel.bind(to: model)
        openWindow(id: "transfers")
    }
}

@MainActor
private enum DockIconVisibility {
    static func show() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    static func hideWhenNoVisibleWindows() {
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApplication.shared.windows.contains {
                $0.isVisible && !$0.isMiniaturized
            }
            if !hasVisibleWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}
