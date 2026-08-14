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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Transfers")
                    .font(.title2.bold())
                Text("Encrypted, resumable file delivery between your paired Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if model.candidateDevices.count > 1 {
                Picker("Destination", selection: $model.selectedDestinationID) {
                    Text("Choose a Mac").tag(DeviceID?.none)
                    ForEach(model.candidateDevices) { device in
                        Text(device.name).tag(DeviceID?.some(device.id))
                    }
                }
                .frame(maxWidth: 220)
                .accessibilityIdentifier("transfer-destination")
            } else if let destination = model.candidateDevices.first {
                Label(destination.name, systemImage: "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
        .padding(20)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No File Transfers", systemImage: "arrow.left.arrow.right.circle")
        } description: {
            Text("Copy files in Finder while controlling another Mac, or choose Send Files to start an encrypted transfer.")
        } actions: {
            Button("Send Files…") { model.chooseFiles() }
                .buttonStyle(.borderedProminent)
                .disabled(model.effectiveDestinationID == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("transfer-empty-state")
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
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.45))
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
        let transferred = formatter.string(fromByteCount: Int64(clamping: transfer.transferredByteCount))
        let total = formatter.string(fromByteCount: Int64(clamping: transfer.totalByteCount))
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
