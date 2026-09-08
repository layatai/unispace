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
    @Published private(set) var loading = false
    @Published var selectedWindow: RemoteWindowID?
    @Published var selectedPeer: DeviceID?
    /// The peer's window list, fetched on demand by `requestRemoteWindows`.
    @Published private(set) var remoteWindows: [SeamlessWindowDescriptor] = []
    @Published var selectedRemoteWindow: RemoteWindowID?
    private let service = SeamlessWindowService()
    private var subscription: AnyCancellable?
    private var configuration: ContinuityWorkspaceConfiguration?
    private weak var appModel: AppModel?
    private static let enabledPreferenceKey = "SeamlessWindowSharingEnabled"

    init() {
        // Restored on the next workspace refresh, not here: starting the
        // service needs `configuration`, which isn't available yet at launch.
        enabled = UserDefaults.standard.bool(forKey: Self.enabledPreferenceKey)
        service.onChange = { [weak self] in
            guard let self else { return }
            let wasBusy = self.busy
            self.status = self.service.status
            self.busy = self.service.isPresenting
            // An incoming window auto-accepts; stop being remotely controlled
            // so local and remote input don't fight over the same window.
            if self.busy && !wasBusy { self.appModel?.stopControlling() }
            let catalog = self.service.remoteCatalog
            self.remoteWindows = catalog?.peer == self.selectedPeer ? (catalog?.windows ?? []) : []
            if !self.remoteWindows.contains(where: { $0.id == self.selectedRemoteWindow }) {
                self.selectedRemoteWindow = self.remoteWindows.first?.id
            }
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

    /// The user-facing toggle: always remembers the preference. Internal
    /// paths that force sharing off for a reason other than the user's own
    /// choice (no workspace yet at launch, a transient failure) go through
    /// `applyEnabled` instead, so a cold start or a hiccup doesn't erase
    /// "the user wants this on" before the workspace has even loaded.
    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enabledPreferenceKey)
        applyEnabled(value)
    }

    private func applyEnabled(_ value: Bool) {
        enabled = value
        if value, let configuration {
            do {
                try service.start(workspace: configuration.workspace, local: configuration.localDevice.id, key: configuration.key)
                Task { await refreshWindows() }
            }
            catch { enabled = false; status = "Window sharing could not start. Check your workspace connection." }
        } else {
            service.stop(); windows = []; selectedWindow = nil
        remoteWindows = []; selectedRemoteWindow = nil
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
        moveWindow(window, to: selectedPeer)
    }
    /// Also used for the menu bar's quick-move list, which skips the picker entirely.
    func moveWindow(_ window: SeamlessWindowDescriptor, to peer: DeviceID) {
        appModel?.stopControlling()
        do { try service.present(window, on: peer) }
        catch { status = "This window could not be shared (\(error)). Keep it visible, check permissions, and enable sharing on the other Mac." }
    }
    func returnHome() { service.returnHome() }

    /// Ask the selected Mac what it can share. Answer arrives via `onChange`.
    func requestRemoteWindows() {
        guard let selectedPeer else { return }
        remoteWindows = []; selectedRemoteWindow = nil
        do { try service.requestCatalog(from: selectedPeer) }
        catch { status = "Could not reach that Mac. Make sure window sharing is on there too." }
    }

    func pullWindow() {
        guard let selectedPeer, let window = remoteWindows.first(where: { $0.id == selectedRemoteWindow }) else { return }
        pullWindow(window, from: selectedPeer)
    }
    /// Also used for the menu bar's quick-pull list.
    func pullWindow(_ window: SeamlessWindowDescriptor, from peer: DeviceID) {
        appModel?.stopControlling()
        do { try service.pull(window, from: peer) }
        catch { status = "That window could not be moved here. Ask for its list again and retry." }
    }

    private func refresh(_ context: ContinuityContextSnapshot, local: DeviceDescriptor) {
        peers = (context.workspace?.devices ?? []).filter { $0.id != local.id && $0.platform == .macOS }
        if !peers.contains(where: { $0.id == selectedPeer }) { selectedPeer = peers.first?.id }
        // This runs on every continuity-context change — device online/offline
        // flicker, control-session updates — not just real workspace changes.
        // Only a genuinely absent workspace should disable an active session;
        // a transient Keychain read failure must not tear one down.
        guard let workspace = context.workspace else {
            configuration = nil; applyEnabled(false); return
        }
        guard let key = try? KeychainTrustStore().workspaceKey(for: workspace.id) else { return }
        let next = ContinuityWorkspaceConfiguration(workspace: workspace, localDevice: local, key: key, capabilities: [])
        guard configuration != next else { return }
        configuration = next
        if enabled { applyEnabled(true) }
    }
}

struct SeamlessWindowView: View {
    @ObservedObject var model: SeamlessWindowViewModel
    @ObservedObject var appModel: AppModel

    private var statusTone: StatusPill.Tone {
        model.busy ? .positive : model.enabled ? .accent : .neutral
    }
    private var statusTitle: String {
        model.busy ? "Sharing" : model.enabled ? "On" : "Off"
    }
    private var needsSeamlessPermissions: Bool {
        appModel.postEventsPermission != .granted || appModel.screenRecordingPermission != .granted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                PageHeader(
                    title: "Seamless Windows",
                    detail: "Show an application window from another Mac alongside your local apps. The application keeps running on its source Mac."
                ) {
                    StatusPill(title: statusTitle, systemImage: model.busy ? "macwindow.on.rectangle" : "power", tone: statusTone)
                }

                permissionsCard
                sharingCard
                if model.enabled {
                    windowsCard
                    remoteWindowsCard
                }

                Text("One Mac-to-Mac window at a time. Double-click a window (or use the menu bar icon) to move it quickly. Keep its source window visible. Closing the remote window ends sharing. Control Option Command Escape returns it home.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: Metrics.contentWidth)
            .padding(Metrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permissions", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets UniSpace click, type and scroll into the moved window on its source Mac.",
                    state: appModel.postEventsPermission,
                    permission: .postEvents,
                    model: appModel
                )
                Divider().padding(.leading, 44)
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Lets UniSpace capture the window it's sharing to another Mac.",
                    state: appModel.screenRecordingPermission,
                    permission: .screenRecording,
                    model: appModel
                )
            }
            .card(padding: 0)
            if needsSeamlessPermissions {
                Label(
                    "After allowing a permission in System Settings, quit and reopen UniSpace so it takes effect.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sharingCard: some View {
        Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "macwindow.on.rectangle", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable window sharing for this session")
                        .font(.body.weight(.semibold))
                    Text(model.status).accessibilityIdentifier("seamless.status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var windowsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Windows on this Mac", systemImage: "macwindow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("Destination Mac", selection: $model.selectedPeer) {
                    Text("Select a Mac").tag(Optional<DeviceID>.none)
                    ForEach(model.peers) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                Button("Refresh") { Task { await model.refreshWindows() } }
                    .disabled(model.busy || model.loading)
            }
            List(selection: $model.selectedWindow) {
                ForEach(model.windows, id: \.id) { window in
                    VStack(alignment: .leading) {
                        Text(window.title).lineLimit(1)
                        Text(window.application).font(.caption).foregroundStyle(.secondary)
                    }.tag(window.id)
                    // Double-click to move immediately, skipping the button below.
                    .onTapGesture(count: 2) {
                        if let peer = model.selectedPeer { model.moveWindow(window, to: peer) }
                    }
                }
            }
            .frame(minHeight: 220)
            .clipShape(.rect(cornerRadius: Metrics.smallRadius, style: .continuous))
            HStack {
                Button("Move Window to Mac") { model.moveWindow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selectedWindow == nil || model.selectedPeer == nil)
                Button("Bring All Windows Home") { model.returnHome() }.disabled(!model.busy)
            }
        }
        .card()
    }

    private var remoteWindowsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Windows on the other Mac", systemImage: "macwindow.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Get List") { model.requestRemoteWindows() }
                    .disabled(model.busy || model.selectedPeer == nil)
            }
            if model.remoteWindows.isEmpty {
                Text("Pick a Mac above and choose Get List to see what it can send here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List(selection: $model.selectedRemoteWindow) {
                    ForEach(model.remoteWindows, id: \.id) { window in
                        VStack(alignment: .leading) {
                            Text(window.title).lineLimit(1)
                            Text(window.application).font(.caption).foregroundStyle(.secondary)
                        }.tag(window.id)
                        .onTapGesture(count: 2) {
                            if let peer = model.selectedPeer { model.pullWindow(window, from: peer) }
                        }
                    }
                }
                .frame(minHeight: 160)
                .clipShape(.rect(cornerRadius: Metrics.smallRadius, style: .continuous))
            }
            Button("Move Window from Mac") { model.pullWindow() }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.selectedRemoteWindow == nil || model.selectedPeer == nil)
        }
        .card()
    }
}
