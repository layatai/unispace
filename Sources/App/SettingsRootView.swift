import SwiftUI
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

struct SettingsRootView: View {
    @ObservedObject var model: AppModel

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
        .padding(24)
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
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Nearby Workspaces").font(.title.bold())
                    Text("Choose the Mac showing Pair New Mac.").foregroundStyle(.secondary)
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
    }

    private var waitingForPeer: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Waiting for another Mac").font(.title2.bold())
            Text("On the other Mac, open UniSpace and choose Join Workspace.")
                .foregroundStyle(.secondary)
            Button("Cancel") { model.cancelPairing() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                PermissionPanel(model: model)
                Divider()
                HStack {
                    Text("Display Topology").font(.title2.bold())
                    Spacer()
                    Text("Drag displays near each other to connect their closest edges.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TopologyEditor(model: model)
                    .frame(height: 250)
                Divider()
                devicesPanel
                Divider()
                Toggle("Launch UniSpace at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.workspace?.name ?? "UniSpace").font(.largeTitle.bold())
                Label(model.statusMessage, systemImage: model.isLocalController ? "cursorarrow.motionlines" : "display")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLocalController {
                Button("Pair New Mac") { model.startHostingPairing() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Make This Mac Controller") { model.makeThisMacController() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var devicesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macs").font(.title2.bold())
            ForEach(model.devices) { device in
                HStack {
                    Circle()
                        .fill(device.id == model.localDeviceID || model.connectedDevices.contains(device.id) ? .green : .gray)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.id == model.localDeviceID ? "This Mac" : "\(device.displays.count) display(s)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.id == model.currentControllerID {
                        Label("Controller", systemImage: "cursorarrow.motionlines").font(.caption)
                    }
                    if device.id != model.localDeviceID {
                        Button(role: .destructive) { model.removeDevice(device.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this Mac and rotate the workspace key")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct PermissionPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            permissionCard(
                title: "Input Monitoring",
                detail: "Captures this Mac’s keyboard and pointer.",
                state: model.inputMonitoringPermission,
                permission: .inputMonitoring
            )
            permissionCard(
                title: "Post Events",
                detail: "Controls the pointer and keyboard on this Mac.",
                state: model.postEventsPermission,
                permission: .postEvents
            )
        }
    }

    private func permissionCard(
        title: String,
        detail: String,
        state: PermissionState,
        permission: PermissionKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state == .granted ? .green : .orange)
                Text(title).font(.headline)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if state != .granted {
                Button("Grant Permission") { model.request(permission) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
                    .fill(.quaternary.opacity(0.35))
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
                                offsets[display.id] = CGSize(
                                    width: origin.width + value.translation.width,
                                    height: origin.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                dragOrigins[display.id] = nil
                                connectNearest(to: display, size: proxy.size)
                            }
                        )
                }
            }
        }
    }

    private var uniqueLinks: [EdgeLink] {
        guard let links = model.workspace?.topology.links else { return [] }
        return links.filter { $0.source.displayID.description < $0.destination.displayID.description }
    }

    private func displayCard(_ display: DisplayDescriptor) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "display")
            Text(deviceName(display.deviceID)).font(.caption.bold()).lineLimit(1)
            Text(display.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 118, height: 70)
        .background(display.deviceID == model.localDeviceID ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2, y: 1)
        .accessibilityElement(children: .combine)
    }

    private func basePosition(index: Int, total: Int, size: CGSize) -> CGPoint {
        let spacing = min(150.0, max(90.0, (size.width - 140) / Double(max(total - 1, 1))))
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
