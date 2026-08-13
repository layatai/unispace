import AppKit
import SwiftUI
import UniSpaceApplication
import UniSpaceDomain

/// The configured-workspace shell: a source list on the left, one detail page
/// on the right, and the controller action promoted into the toolbar.
struct WorkspaceView: View {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general
        case displays
        case macs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .displays: "Displays"
            case .macs: "Macs"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .displays: "rectangle.3.group"
            case .macs: "laptopcomputer"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var selection: Section = .general

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
            ForEach(Section.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(section == .macs ? model.devices.count : 0)
                    .tag(section)
                    .accessibilityIdentifier("section-\(section.rawValue)")
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
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
                    Text("\(model.connectedDevices.count + 1) of \(max(model.devices.count, 1)) Macs online")
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
        case .macs:
            DevicesView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isLocalController {
                Button {
                    model.startHostingPairing()
                } label: {
                    Label("Pair New Mac", systemImage: "plus")
                }
                .help("Add another Mac to this workspace")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                statusHero
                permissionsSection
                startupSection
                shortcutTip
            }
            .frame(maxWidth: Metrics.contentWidth)
            .padding(Metrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                        .font(.body.weight(.medium))
                    Text("Keep UniSpace ready as soon as you sign in to this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
