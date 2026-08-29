import SwiftUI

/// Routes between the pre-workspace setup flow and the configured workspace
/// shell, and owns the app-wide error presentation.
struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboardModel: ClipboardViewModel
    @ObservedObject var transferModel: FileTransferViewModel
    @Binding var selection: WorkspaceView.Destination
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if case .ready = model.setupState {
                WorkspaceView(
                    model: model,
                    clipboardModel: clipboardModel,
                    transferModel: transferModel,
                    selection: $selection
                )
                    .transition(.opacity)
            } else {
                SetupFlowView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .unispace, value: model.setupState)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }
}
