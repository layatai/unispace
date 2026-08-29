import AppKit
import SwiftUI

@main
struct UniSpaceApp: App {
    @NSApplicationDelegateAdaptor(UniSpaceApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var transferModel = FileTransferViewModel()
    @StateObject private var clipboardModel = ClipboardViewModel()
    @State private var selection: WorkspaceView.Destination = .general
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("UniSpace", id: "main") {
            SettingsRootView(
                model: model,
                clipboardModel: clipboardModel,
                transferModel: transferModel,
                selection: $selection
            )
                .frame(minWidth: 760, minHeight: 540)
                .onAppear {
                    DockIconVisibility.show()
                    model.refreshPermissions()
                    transferModel.bind(to: model)
                    clipboardModel.bind(to: model)
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
                Button("Show Continuity") { openContinuity() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.workspace == nil)
                Button("Show File Transfers") { openTransferCenter() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
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
            Button("Continuity…") { openContinuity() }
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

    private func openContinuity() {
        openMainWindow(selecting: .continuity)
    }

    private func openTransferCenter() {
        openMainWindow(selecting: .transfers)
    }

    private func openMainWindow(selecting destination: WorkspaceView.Destination) {
        selection = destination
        DockIconVisibility.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

@MainActor
private final class UniSpaceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        DockIconVisibility.hideWhenNoVisibleWindows()
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
                $0.isVisible
                    && !$0.isMiniaturized
                    && $0.styleMask.contains(.titled)
                    && $0.level == .normal
            }
            if !hasVisibleWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}
