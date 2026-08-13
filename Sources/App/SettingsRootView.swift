import AppKit
import SwiftUI
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

struct SettingsRootView: View {
    private enum Section: Hashable {
        case general
        case displays
        case devices
    }

    @ObservedObject var model: AppModel
    @State private var selectedSection: Section = .general

    var body: some View {
        Group {
            switch model.setupState {
            case .needsWorkspace:
                onboarding
            case .browsing:
                candidateList
            case let .confirming(prompt):
                pairingConfirmation(prompt)
            case .hostingPairing:
                waitingForPeer
            case .ready:
                readyView
            }
        }
        .accessibilityIdentifier("unispace-main-view")
        .alert("UniSpace Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }

    private var onboarding: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("One keyboard. Every Mac.")
                .font(.largeTitle.bold())
            Text("Create a trusted local workspace or join one from another Mac running UniSpace.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button("Create Workspace") { model.createWorkspace() }
                    .buttonStyle(.borderedProminent)
                Button("Join Workspace") { model.startBrowsingForWorkspace() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Nearby Workspaces").font(.title.bold())
                    Text("On an existing Mac, open Macs and choose Pair New Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small)
            }
            List(model.candidates) { candidate in
                HStack {
                    Image(systemName: "laptopcomputer")
                    Text(candidate.name)
                    Spacer()
                    Button("Join") { model.join(candidate) }
                }
            }
            Button("Cancel") { model.cancelPairing() }
        }
        .padding(24)
    }

    private func pairingConfirmation(_ prompt: PairingPrompt) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Confirm Pairing").font(.title.bold())
            Text("Verify that this code is identical on \(prompt.peer.name).")
                .foregroundStyle(.secondary)
            Text(prompt.code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .padding(.vertical, 10)
                .accessibilityLabel("Pairing code \(prompt.code)")
            HStack {
                Button("Cancel") { model.cancelPairing() }
                Button("Codes Match") { model.confirmPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var waitingForPeer: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Waiting for another Mac").font(.title2.bold())
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
            Text("On the other Mac, open UniSpace and choose Join Workspace. Both Macs must allow Local Network access.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { model.cancelPairing() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var readyView: some View {
        TabView(selection: $selectedSection) {
            generalSection
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Section.general)
            displaysSection
                .tabItem { Label("Displays", systemImage: "rectangle.3.group") }
                .tag(Section.displays)
            devicesSection
                .tabItem { Label("Macs", systemImage: "laptopcomputer.and.iphone") }
                .tag(Section.devices)
        }
        .padding(.top, 8)
    }

    private var generalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusCard
                PermissionPanel(model: model)
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Launch at login")
                                .font(.headline)
                            Text("Keep UniSpace ready after signing in to this Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(4)
                } label: {
                    Label("Startup", systemImage: "power")
                }
            }
            .frame(maxWidth: 650)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.workspace?.name ?? "UniSpace")
                    .font(.title.bold())
                Label(
                    model.statusMessage,
                    systemImage: model.isLocalController ? "cursorarrow.motionlines" : "display"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLocalController {
                Label("Controller", systemImage: "cursorarrow.motionlines")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(.tint)
            } else {
                Button("Make This Mac Controller") {
                    model.makeThisMacController()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                title: "Display Topology",
                detail: "Arrange how the pointer moves between displays on your Macs."
            )
            TopologyEditor(model: model)
                .frame(minHeight: 320)
            HStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .foregroundStyle(.tint)
                Text("Drag a display next to one on another Mac. UniSpace connects their nearest edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                pageHeader(
                    title: "Macs",
                    detail: "\(model.devices.count) of 4 Macs in this workspace"
                )
                Spacer()
                HStack(spacing: 10) {
                    if !model.isLocalController {
                        Button("Make This Mac Controller") { model.makeThisMacController() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    Button("Pair New Mac") { model.startHostingPairing() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.devices.count >= 4)
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.devices) { device in
                        deviceCard(device)
                    }
                }
            }
        }
        .padding(28)
    }

    private func pageHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.bold())
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func deviceCard(_ device: DeviceDescriptor) -> some View {
        let isLocal = device.id == model.localDeviceID
        let isOnline = isLocal || model.connectedDevices.contains(device.id)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isLocal ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(isLocal ? Color.accentColor : Color.secondary)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(device.name)
                        .font(.headline)
                    if isLocal {
                        Text("THIS MAC")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(isOnline ? "Available" : "Offline")
                    Text("•")
                    Text("\(device.displays.count) \(device.displays.count == 1 ? "display" : "displays")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if device.id == model.currentControllerID {
                Label("Controller", systemImage: "cursorarrow.motionlines")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }
            if !isLocal {
                Button(role: .destructive) {
                    model.removeDevice(device.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget this Mac and rotate the workspace key")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.65)))
    }
}

private struct PermissionPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Captures this Mac’s keyboard and pointer.",
                    state: model.inputMonitoringPermission,
                    permission: .inputMonitoring
                )
                Divider()
                    .padding(.leading, 38)
                permissionRow(
                    title: "Post Events",
                    detail: "Controls the pointer and keyboard on this Mac.",
                    state: model.postEventsPermission,
                    permission: .postEvents
                )
            }
        } label: {
            Label("Permissions", systemImage: "hand.raised")
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        state: PermissionState,
        permission: PermissionKind
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(state == .granted ? .green : .orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Text("Allowed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Grant Permission") {
                    model.request(permission)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

private struct TopologyEditor: View {
    @ObservedObject var model: AppModel
    @State private var offsets: [DisplayID: CGSize] = [:]
    @State private var dragOrigins: [DisplayID: CGSize] = [:]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                Canvas { context, _ in
                    for link in uniqueLinks {
                        guard let source = position(for: link.source.displayID, in: proxy.size),
                              let destination = position(for: link.destination.displayID, in: proxy.size) else { continue }
                        var path = Path()
                        path.move(to: source)
                        path.addLine(to: destination)
                        context.stroke(path, with: .color(.accentColor.opacity(0.7)), lineWidth: 2)
                    }
                }
                ForEach(Array(model.allDisplays.enumerated()), id: \.element.id) { index, display in
                    displayCard(display)
                        .position(basePosition(index: index, total: model.allDisplays.count, size: proxy.size))
                        .offset(offsets[display.id] ?? .zero)
                        .gesture(DragGesture()
                            .onChanged { value in
                                let origin = dragOrigins[display.id] ?? offsets[display.id] ?? .zero
                                dragOrigins[display.id] = origin
                                let base = basePosition(
                                    index: index,
                                    total: model.allDisplays.count,
                                    size: proxy.size
                                )
                                let proposed = CGPoint(
                                    x: base.x + origin.width + value.translation.width,
                                    y: base.y + origin.height + value.translation.height
                                )
                                let clamped = CGPoint(
                                    x: min(max(proposed.x, 78), proxy.size.width - 78),
                                    y: min(max(proposed.y, 48), proxy.size.height - 48)
                                )
                                offsets[display.id] = CGSize(
                                    width: clamped.x - base.x,
                                    height: clamped.y - base.y
                                )
                            }
                            .onEnded { _ in
                                dragOrigins[display.id] = nil
                                connectNearest(to: display, size: proxy.size)
                            }
                        )
                }
                if model.devices.count < 2 {
                    VStack {
                        Spacer()
                        Label("Pair another Mac to connect displays.", systemImage: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 14)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.7)))
        }
    }

    private var uniqueLinks: [EdgeLink] {
        guard let links = model.workspace?.topology.links else { return [] }
        return links.filter { $0.source.displayID.description < $0.destination.displayID.description }
    }

    private func displayCard(_ display: DisplayDescriptor) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "display")
                .font(.title3)
            Text(deviceName(display.deviceID)).font(.caption.bold()).lineLimit(1)
            Text(display.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 138, height: 78)
        .background(display.deviceID == model.localDeviceID ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 2, y: 1)
        .accessibilityElement(children: .combine)
    }

    private func basePosition(index: Int, total: Int, size: CGSize) -> CGPoint {
        let spacing = min(175.0, max(105.0, (size.width - 170) / Double(max(total - 1, 1))))
        let start = size.width / 2 - spacing * Double(total - 1) / 2
        return CGPoint(x: start + Double(index) * spacing, y: size.height / 2)
    }

    private func position(for id: DisplayID, in size: CGSize) -> CGPoint? {
        guard let index = model.allDisplays.firstIndex(where: { $0.id == id }) else { return nil }
        let base = basePosition(index: index, total: model.allDisplays.count, size: size)
        let offset = offsets[id] ?? .zero
        return CGPoint(x: base.x + offset.width, y: base.y + offset.height)
    }

    private func connectNearest(to source: DisplayDescriptor, size: CGSize) {
        guard let sourcePosition = position(for: source.id, in: size) else { return }
        let candidates = model.allDisplays.filter { $0.id != source.id && $0.deviceID != source.deviceID }
        guard let target = candidates.min(by: {
            distance(sourcePosition, position(for: $0.id, in: size) ?? .zero)
                < distance(sourcePosition, position(for: $1.id, in: size) ?? .zero)
        }), let targetPosition = position(for: target.id, in: size),
              distance(sourcePosition, targetPosition) < 260 else { return }
        let dx = targetPosition.x - sourcePosition.x
        let dy = targetPosition.y - sourcePosition.y
        let sourceEdge: DisplayEdge
        let targetEdge: DisplayEdge
        if abs(dx) >= abs(dy) {
            sourceEdge = dx >= 0 ? .right : .left
            targetEdge = sourceEdge.opposite
        } else {
            sourceEdge = dy >= 0 ? .bottom : .top
            targetEdge = sourceEdge.opposite
        }
        model.connect(
            DisplayEndpoint(displayID: source.id, edge: sourceEdge),
            to: DisplayEndpoint(displayID: target.id, edge: targetEdge)
        )
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func deviceName(_ id: DeviceID) -> String {
        model.devices.first(where: { $0.id == id })?.name ?? "Mac"
    }
}
