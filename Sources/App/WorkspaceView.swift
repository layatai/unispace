import AppKit
import SwiftUI
import UniSpaceApplication
import UniSpaceDomain

/// The configured-workspace shell: a source list on the left, one detail page
/// on the right, and the controller action promoted into the toolbar.
struct WorkspaceView: View {
    enum Destination: String, Hashable, Identifiable {
        case general
        case displays
        case devices
        case continuity
        case transfers

        var id: String { rawValue }

        static let workspace: [Self] = [.general, .displays, .devices]
        static let sharing: [Self] = [.continuity, .transfers]

        var title: String {
            switch self {
            case .general: "General"
            case .displays: "Displays"
            case .devices: "Devices"
            case .continuity: "Continuity"
            case .transfers: "File Transfers"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .displays: "rectangle.3.group"
            case .devices: "laptopcomputer"
            case .continuity: "doc.on.clipboard"
            case .transfers: "arrow.left.arrow.right.circle"
            }
        }
    }

    @ObservedObject var model: AppModel
    @ObservedObject var clipboardModel: ClipboardViewModel
    @ObservedObject var transferModel: FileTransferViewModel
    @Binding var selection: Destination

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .navigationTitle("UniSpace")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            SwiftUI.Section("Workspace") {
                ForEach(Destination.workspace) { destination in
                    sidebarRow(destination)
                }
            }
            SwiftUI.Section("Sharing") {
                ForEach(Destination.sharing) { destination in
                    sidebarRow(destination)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    @ViewBuilder
    private func sidebarRow(_ destination: Destination) -> some View {
        HStack(spacing: 8) {
            Label(destination.title, systemImage: destination.systemImage)
                .accessibilityIdentifier("section-\(destination.rawValue)")
            Spacer(minLength: 0)
            if destination == .continuity, clipboardModel.sharingEnabled {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Enabled")
            }
        }
        .badge(destination == .devices ? model.devices.count : transferBadge(destination))
        .tag(destination)
    }

    private func transferBadge(_ destination: Destination) -> Int {
        destination == .transfers ? transferModel.activeTransferCount : 0
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 9) {
                Circle()
                    .fill(model.isLocalController ? Color.accentColor : Color.secondary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isLocalController ? "Controlling" : "Receiving")
                        .font(.caption.weight(.semibold))
                    Text("\(model.connectedDevices.count + 1) of \(max(model.devices.count, 1)) devices online")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralView(model: model)
        case .displays:
            DisplaysView(model: model)
        case .devices:
            DevicesView(model: model)
        case .continuity:
            ContinuityView(model: clipboardModel)
        case .transfers:
            TransferCenterView(model: transferModel)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isLocalController {
                Button {
                    model.startHostingPairing()
                } label: {
                    Label("Pair New Device", systemImage: "plus")
                }
                .help("Add another device to this workspace")
                .disabled(model.devices.count >= 4)
            } else {
                Button {
                    model.makeThisMacController()
                } label: {
                    Label("Use This Keyboard", systemImage: "cursorarrow.motionlines")
                }
                .help("Make this Mac the controller for the workspace")
            }
        }
    }
}

// MARK: - General

struct GeneralView: View {
    @ObservedObject var model: AppModel
    @State private var isConfirmingLeave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                statusHero
                permissionsSection
                startupSection
                shortcutTip
                workspaceSection
            }
            .frame(maxWidth: Metrics.contentWidth)
            .padding(Metrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(
            "Leave “\(model.workspace?.name ?? "this workspace")”?",
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Workspace", role: .destructive) {
                Task { await model.leaveWorkspace() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac will forget the workspace and return to setup. Other devices and macOS permissions are unchanged.")
        }
    }

    // MARK: Hero

    private var statusHero: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.workspace?.name ?? "UniSpace")
                    .font(.title2.bold())
                Text(model.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.isLocalController {
                StatusPill(
                    title: "Controller",
                    systemImage: "cursorarrow.motionlines",
                    tone: .accent
                )
            } else {
                Button("Make This Mac Controller") {
                    model.makeThisMacController()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.heroRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: Metrics.heroRadius, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                LinearGradient(
                    colors: [Color.accentColor.opacity(model.isLocalController ? 0.16 : 0.06), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(.rect(cornerRadius: Metrics.heroRadius, style: .continuous))
            )
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Permissions", systemImage: "hand.raised")

            VStack(spacing: 0) {
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets UniSpace read this Mac’s keyboard and pointer so it can forward them.",
                    state: model.inputMonitoringPermission,
                    permission: .inputMonitoring,
                    model: model
                )
                Divider().padding(.leading, 44)
                PermissionRow(
                    title: "Post Events",
                    detail: "Lets another Mac move the pointer and type on this Mac.",
                    state: model.postEventsPermission,
                    permission: .postEvents,
                    model: model
                )
            }
            .card(padding: 0)

            if model.needsPermissions {
                Label(
                    "After allowing a permission in System Settings, quit and reopen UniSpace so it takes effect.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Startup", systemImage: "power")

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                            .font(.body.weight(.medium))
                        Text("Keep UniSpace ready as soon as you sign in to this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.switch)
            .card()
            .accessibilityIdentifier("launch-at-login")
        }
    }

    private var shortcutTip: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "keyboard", tint: .secondary, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Take back control instantly")
                    .font(.subheadline.weight(.semibold))
                Text("Press Control-Option-Command-Escape to end a remote session and return to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Workspace", systemImage: "rectangle.portrait.and.arrow.right")

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Join a different workspace")
                        .font(.body.weight(.medium))
                    Text("Leave this workspace to return to setup. This only removes UniSpace data for this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("Leave Workspace…", role: .destructive) {
                    isConfirmingLeave = true
                }
                .accessibilityIdentifier("leave-workspace")
            }
            .card()
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// One permission row, with an escape hatch to System Settings because the
/// system prompt only ever appears once per app.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let permission: PermissionKind
    @ObservedObject var model: AppModel

    private var isGranted: Bool { state == .granted }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isGranted {
                StatusPill(title: "Allowed", systemImage: "checkmark", tone: .positive)
            } else {
                HStack(spacing: 8) {
                    Button("Allow…") { model.request(permission) }
                        .buttonStyle(.borderedProminent)
                    Button {
                        model.openSystemSettings(for: permission)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("Open this permission in System Settings")
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(isGranted ? "Allowed" : "Not allowed")")
    }
}
