import SwiftUI
import UniSpaceApplication
import UniSpaceDomain

/// The roster of Macs in the workspace, with online state, controller state,
/// and removal.
struct DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var pendingRemoval: DeviceDescriptor?
    @State private var addressDevice: DeviceDescriptor?
    @State private var connectionAddress = ""

    private let capacity = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                PageHeader(
                    title: "Macs",
                    detail: "\(model.devices.count) of \(capacity) Macs paired in this workspace."
                ) {
                    capacityMeter
                }

                LazyVStack(spacing: 10) {
                    ForEach(sortedDevices) { device in
                        deviceCard(device)
                    }
                }

                if model.devices.count < capacity, model.isLocalController {
                    addCard
                }
            }
            .frame(maxWidth: Metrics.contentWidth)
            .padding(Metrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(
            "Forget “\(pendingRemoval?.name ?? "this Mac")”?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget Mac", role: .destructive) {
                if let pendingRemoval {
                    model.removeDevice(pendingRemoval.id)
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This Mac leaves the workspace and the shared key is replaced. You can pair it again later.")
        }
        .sheet(item: $addressDevice) { device in
            connectionAddressSheet(device)
        }
    }

    /// Local Mac first, then everything else alphabetically — a stable order
    /// that does not reshuffle as peers connect.
    private var sortedDevices: [DeviceDescriptor] {
        model.devices.sorted { first, second in
            if first.id == model.localDeviceID { return true }
            if second.id == model.localDeviceID { return false }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private var capacityMeter: some View {
        HStack(spacing: 4) {
            ForEach(0..<capacity, id: \.self) { index in
                Capsule()
                    .fill(index < model.devices.count ? Color.accentColor : Theme.surfaceStrong)
                    .frame(width: 18, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func deviceCard(_ device: DeviceDescriptor) -> some View {
        let isLocal = device.id == model.localDeviceID
        let isOnline = isLocal || model.connectedDevices.contains(device.id)
        let isController = device.id == model.currentControllerID
        let connection = model.connectionSnapshots[device.id]
        let connectionColor: Color = connection?.health == .degraded || connection?.health == .reconnecting
            ? .orange
            : .green

        return HStack(spacing: 14) {
            IconTile(
                systemImage: "laptopcomputer",
                tint: isLocal ? .accentColor : .secondary,
                size: 46
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(device.name)
                        .font(.headline)
                    if isLocal {
                        Text("This Mac")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceStrong, in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnline ? connectionColor : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(isOnline ? "Available" : "Offline")
                    if isOnline, !isLocal, let connection {
                        Text("·")
                        Text(connectionDescription(connection))
                    }
                    Text("·")
                    Text(displayCount(device))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isController {
                StatusPill(title: "Controller", systemImage: "cursorarrow.motionlines", tone: .accent)
            }

            if !isLocal {
                Button {
                    connectionAddress = device.peerAddresses.first?.host ?? ""
                    addressDevice = device
                } label: {
                    Image(systemName: "network")
                }
                .buttonStyle(.borderless)
                .help("Set Tailscale connection address")
                .accessibilityLabel("Set connection address for \(device.name)")

                Button(role: .destructive) {
                    pendingRemoval = device
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget this Mac and replace the workspace key")
                .accessibilityLabel("Forget \(device.name)")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private func connectionAddressSheet(_ device: DeviceDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to \(device.name)")
                .font(.title2.bold())
            Text("Enter this Mac’s MagicDNS name or Tailscale IP. UniSpace will keep Bonjour enabled for nearby connections.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("macbook.tailnet.ts.net or 100.x.x.x", text: $connectionAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveConnectionAddress(for: device) }
            HStack {
                Spacer()
                Button("Cancel") { addressDevice = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveConnectionAddress(for: device) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connectionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func saveConnectionAddress(for device: DeviceDescriptor) {
        model.setConnectionAddress(connectionAddress, for: device.id)
        addressDevice = nil
    }

    private var addCard: some View {
        Button {
            model.startHostingPairing()
        } label: {
            HStack(spacing: 14) {
                IconTile(systemImage: "plus", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair New Mac")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Show a pairing code another Mac can join over LAN or Tailscale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        Theme.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pair-new-mac")
    }

    private func displayCount(_ device: DeviceDescriptor) -> String {
        let count = device.displays.count
        return count == 1 ? "1 display" : "\(count) displays"
    }

    private func connectionDescription(_ connection: ConnectionSnapshot) -> String {
        var parts = [connection.transport.rawValue.uppercased()]
        if connection.health == .degraded { parts.append("Slow") }
        if connection.health == .reconnecting { parts.append("Reconnecting") }
        if let latency = connection.latencyMilliseconds { parts.append("\(latency) ms") }
        return parts.joined(separator: " · ")
    }
}
