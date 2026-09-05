import AppKit
import Combine
import SwiftUI
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class SeamlessWindowViewModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Window sharing is off"
    @Published private(set) var windows: [SeamlessWindowDescriptor] = []
    @Published private(set) var peers: [DeviceDescriptor] = []
    @Published private(set) var incomingTitle: String?
    @Published private(set) var loading = false
    @Published var selectedWindow: RemoteWindowID?
    @Published var selectedPeer: DeviceID?
    private let service = SeamlessWindowService()
    private var subscription: AnyCancellable?
    private var configuration: ContinuityWorkspaceConfiguration?
    private weak var appModel: AppModel?

    init() {
        service.onChange = { [weak self] in
            guard let self else { return }
            self.status = self.service.status
            self.busy = self.service.isPresenting
            self.incomingTitle = self.service.incoming?.1.title
        }
    }

    func bind(to appModel: AppModel) {
        guard subscription == nil else { return }
        self.appModel = appModel
        subscription = appModel.continuityContextPublisher.receive(on: RunLoop.main).sink { [weak self, weak appModel] context in
            guard let self, let appModel else { return }
            self.refresh(context, local: appModel.localDevice)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value, let configuration {
            do { try service.start(workspace: configuration.workspace, local: configuration.localDevice.id, key: configuration.key) }
            catch { enabled = false; status = "Window sharing could not start. Check your workspace connection." }
        } else {
            service.stop(); windows = []; selectedWindow = nil
            if value { enabled = false; status = "Join a workspace before enabling window sharing." }
        }
    }

    func refreshWindows() async {
        guard enabled, !loading, !busy else { return }
        loading = true
        defer { loading = false }
        // Use the documented option key's value; older SDKs import the C
        // constant as shared mutable state under Swift 6 strict concurrency.
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            status = "Allow UniSpace in System Settings → Privacy & Security → Accessibility, then refresh."; return
        }
        do {
            let list = try await service.catalog()
            guard enabled else { return }
            windows = list
            if !list.contains(where: { $0.id == selectedWindow }) { selectedWindow = list.first?.id }
        } catch { status = "Allow UniSpace in System Settings → Privacy & Security → Screen Recording, then refresh." }
    }

    func moveWindow() {
        guard let selectedPeer, let window = windows.first(where: { $0.id == selectedWindow }) else { return }
        appModel?.stopControlling()
        do { try service.present(window, on: selectedPeer) }
        catch { status = "This window could not be shared. Keep it visible, check permissions, and enable sharing on the other Mac." }
    }
    func accept() { appModel?.stopControlling(); service.accept() }
    func returnHome() { service.returnHome() }

    private func refresh(_ context: ContinuityContextSnapshot, local: DeviceDescriptor) {
        peers = (context.workspace?.devices ?? []).filter { $0.id != local.id && $0.platform == .macOS }
        if !peers.contains(where: { $0.id == selectedPeer }) { selectedPeer = peers.first?.id }
        guard let workspace = context.workspace,
              let key = try? KeychainTrustStore().workspaceKey(for: workspace.id) else {
            configuration = nil; setEnabled(false); return
        }
        let next = ContinuityWorkspaceConfiguration(workspace: workspace, localDevice: local, key: key, capabilities: [])
        guard configuration != next else { return }
        configuration = next
        if enabled { setEnabled(true) }
    }
}

struct SeamlessWindowView: View {
    @ObservedObject var model: SeamlessWindowViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Seamless Windows").font(.title)
            Text("Show an application window from another Mac alongside your local apps. The application keeps running on its source Mac.")
                .foregroundStyle(.secondary)
            Toggle("Enable window sharing for this session", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Text(model.status).accessibilityIdentifier("seamless.status")
            if let title = model.incomingTitle {
                GroupBox("Incoming window") {
                    VStack(alignment: .leading) {
                        Text(title)
                        HStack {
                            Button("Accept Window") { model.accept() }
                            Button("Decline") { model.returnHome() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Picker("Destination Mac", selection: $model.selectedPeer) {
                    Text("Select a Mac").tag(Optional<DeviceID>.none)
                    ForEach(model.peers) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Refresh Windows") { Task { await model.refreshWindows() } }
                    .disabled(!model.enabled || model.busy || model.loading)
            }
            List(selection: $model.selectedWindow) {
                ForEach(model.windows, id: \.id) { window in
                    VStack(alignment: .leading) {
                        Text(window.title).lineLimit(1)
                        Text(window.application).font(.caption).foregroundStyle(.secondary)
                    }.tag(window.id)
                }
            }.frame(minHeight: 180)
            HStack {
                Button("Move Window to Mac") { model.moveWindow() }
                    .disabled(!model.enabled || model.busy || model.selectedWindow == nil || model.selectedPeer == nil)
                Button("Bring All Windows Home") { model.returnHome() }.disabled(!model.busy)
            }
            Text("Preview: one Mac-to-Mac window at a time. Keep its source window visible. Closing the remote window ends sharing. Control Option Command Escape returns it home.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 500)
    }
}
