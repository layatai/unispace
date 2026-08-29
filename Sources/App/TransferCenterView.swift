import SwiftUI
import UniSpaceApplication
import UniSpaceDomain

struct TransferCenterView: View {
    @ObservedObject var model: FileTransferViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.transfers.isEmpty {
                emptyState
            } else {
                transferList
            }
        }
        .alert(
            "File Transfer",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "The transfer could not be completed.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Transfers",
                detail: "Encrypted, resumable file delivery between paired Macs and Windows PCs."
            )

            HStack(spacing: 12) {
                destinationControl
                Spacer(minLength: 16)
                Button {
                    model.chooseFiles()
                } label: {
                    Label("Send Files…", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.effectiveDestinationID == nil)
                .accessibilityIdentifier("send-files")
                Button("Clear Completed") {
                    model.clearCompleted()
                }
                .disabled(!model.transfers.contains(where: { $0.state.isTerminal }))
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var destinationControl: some View {
        if model.candidateDevices.count > 1 {
            Picker("Send to", selection: $model.selectedDestinationID) {
                Text("Choose a device").tag(DeviceID?.none)
                ForEach(model.candidateDevices) { device in
                    Text(device.name).tag(DeviceID?.some(device.id))
                }
            }
            .frame(maxWidth: 240)
            .accessibilityIdentifier("transfer-destination")
        } else if let destination = model.candidateDevices.first {
            Label(destination.name, systemImage: deviceIcon(destination))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Label("No compatible device online", systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No File Transfers", systemImage: "arrow.left.arrow.right.circle")
        } description: {
            if model.candidateDevices.isEmpty {
                Text("Bring a paired Mac or Windows PC online, then copy files or use Send Files.")
            } else if model.effectiveDestinationID == nil {
                Text("The paired device is online, but its encrypted file-transfer channel is not ready yet.")
            } else {
                Text("Copy files while controlling another device, or choose Send Files to start an encrypted transfer.")
            }
        } actions: {
            Button("Send Files…") { model.chooseFiles() }
                .buttonStyle(.borderedProminent)
                .disabled(model.effectiveDestinationID == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("transfer-empty-state")
    }

    private func deviceIcon(_ device: DeviceDescriptor) -> String {
        device.platform == .windows ? "pc" : "laptopcomputer"
    }

    private var transferList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.transfers) { transfer in
                    TransferRow(
                        transfer: transfer,
                        peerName: model.deviceName(transfer.peerDeviceID),
                        onCancel: { model.cancel(transfer.id) },
                        onRetry: { model.retry(transfer.id) },
                        onReveal: { model.reveal(transfer) },
                        onExport: { model.export(transfer) },
                        onRemove: { model.remove(transfer.id) }
                    )
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("transfer-list")
    }
}

private struct TransferRow: View {
    let transfer: FileTransferSnapshot
    let peerName: String
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onReveal: () -> Void
    let onExport: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transfer.direction == .incoming
                      ? "arrow.down.circle.fill"
                      : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(transfer.state == .failed ? .red : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Label(stateTitle, systemImage: stateImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateForeground)
            }

            if transfer.isActive {
                ProgressView(value: transfer.progress)
                    .accessibilityValue("\(Int(transfer.progress * 100)) percent")
            }

            HStack(spacing: 10) {
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                actions
            }
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-\(transfer.id.rawValue.uuidString)")
    }

    @ViewBuilder
    private var actions: some View {
        switch transfer.state {
        case .offered, .awaitingAcceptance, .preparing, .transferring, .paused, .verifying:
            Button("Cancel", role: .destructive, action: onCancel)
        case .failed:
            Button("Retry", action: onRetry)
            Button("Remove", action: onRemove)
        case .completed:
            if transfer.direction == .incoming {
                Button("Reveal", action: onReveal)
                    .disabled(transfer.stagedURLs.isEmpty)
                Button("Save As…", action: onExport)
                    .disabled(transfer.stagedURLs.isEmpty)
            }
            Button("Remove", action: onRemove)
        case .cancelled:
            Button("Remove", action: onRemove)
        }
    }

    private var subtitle: String {
        let direction = transfer.direction == .incoming ? "From" : "To"
        let count = transfer.fileCount == 1 ? "1 file" : "\(transfer.fileCount) files"
        return "\(direction) \(peerName) · \(count)"
    }

    private var progressText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let transferred = formatter.string(
            fromByteCount: Int64(clamping: transfer.transferredByteCount)
        )
        let total = formatter.string(
            fromByteCount: Int64(clamping: transfer.totalByteCount)
        )
        return transfer.state == .completed ? total : "\(transferred) of \(total)"
    }

    private var stateTitle: String {
        switch transfer.state {
        case .offered, .awaitingAcceptance: "Waiting"
        case .preparing: "Preparing"
        case .transferring: "Transferring"
        case .paused: "Paused"
        case .verifying: "Verifying"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    private var stateImage: String {
        switch transfer.state {
        case .offered, .awaitingAcceptance: "clock"
        case .preparing: "shippingbox"
        case .transferring: "arrow.left.arrow.right"
        case .paused: "pause.circle"
        case .verifying: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var stateForeground: Color {
        switch transfer.state {
        case .completed: .green
        case .failed: .red
        case .cancelled, .paused: .secondary
        default: .accentColor
        }
    }
}
