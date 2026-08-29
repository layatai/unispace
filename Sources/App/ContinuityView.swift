import SwiftUI

struct ContinuityView: View {
    @ObservedObject var model: ClipboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                PageHeader(
                    title: "Continuity",
                    detail: "Carry text and links between the device you are using and the active UniSpace peer."
                ) {
                    StatusPill(
                        title: model.sharingEnabled ? "Enabled" : "Off",
                        systemImage: model.sharingEnabled ? "checkmark" : "pause",
                        tone: model.sharingEnabled ? .positive : .neutral
                    )
                }

                sharingCard
                activePeerCard
                privacyCard
            }
            .frame(maxWidth: Metrics.contentWidth)
            .padding(Metrics.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert(
            "Clipboard sharing unavailable",
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

    private var sharingCard: some View {
        Toggle(isOn: Binding(
            get: { model.sharingEnabled },
            set: { model.setSharingEnabled($0) }
        )) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "doc.on.clipboard", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share clipboard with active device")
                        .font(.body.weight(.semibold))
                    Text("Automatically synchronize copied text and links. Files continue through UniSpace’s verified file-transfer flow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .card()
        .accessibilityIdentifier("clipboard-sharing-toggle")
    }

    private var activePeerCard: some View {
        HStack(spacing: 14) {
            IconTile(
                systemImage: model.isDestinationConnected ? "link" : "link.badge.plus",
                tint: model.isDestinationConnected ? .green : .secondary,
                size: 40
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("Active peer")
                    .font(.body.weight(.semibold))
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.sharingEnabled {
                StatusPill(
                    title: model.isDestinationConnected ? "Encrypted" : "Waiting",
                    systemImage: model.isDestinationConnected ? "lock.fill" : "clock",
                    tone: model.isDestinationConnected ? .positive : .warning
                )
            }
        }
        .card()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Private by design", systemImage: "hand.raised.fill")
                .font(.headline)
            privacyRow(
                systemImage: "cursorarrow.motionlines",
                title: "Active peer only",
                detail: "Clipboard data is never broadcast to every device in the workspace."
            )
            Divider()
            privacyRow(
                systemImage: "lock.shield",
                title: "Authenticated and encrypted",
                detail: "Updates use a dedicated ChaCha20-Poly1305 channel authenticated by the trusted workspace key."
            )
            Divider()
            privacyRow(
                systemImage: "clock.arrow.circlepath",
                title: "No clipboard history",
                detail: "UniSpace keeps only bounded identifiers and hashes in memory to prevent loops and resolve simultaneous changes."
            )
        }
        .card()
    }

    private func privacyRow(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
