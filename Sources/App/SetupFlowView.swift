import AppKit
import SwiftUI
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

/// Everything the user sees before a workspace exists: the welcome screen,
/// workspace discovery, and the two-sided pairing confirmation.
struct SetupFlowView: View {
    private static let macifierDownloadURL = URL(
        string: "https://github.com/layatai/macifier-app/releases/latest"
    )!

    @ObservedObject var model: AppModel
    @State private var directAddress = ""

    var body: some View {
        Group {
            switch model.setupState {
            case .needsWorkspace:
                welcome
            case .browsing:
                discovery
            case let .confirming(prompt):
                confirmation(prompt)
            case .hostingPairing:
                hosting
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 20)

            Text("One keyboard. Every device.")
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Move your pointer between devices as if they shared one desk, over your LAN or private Tailscale network.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 8)

            HStack(spacing: 14) {
                choiceCard(
                    title: "Create Workspace",
                    detail: "Start here on the Mac whose keyboard you want to use.",
                    systemImage: "plus.circle",
                    isPrimary: true
                ) {
                    model.createWorkspace()
                }
                choiceCard(
                    title: "Join Workspace",
                    detail: "Add this Mac to a workspace another Mac already created.",
                    systemImage: "antenna.radiowaves.left.and.right",
                    isPrimary: false
                ) {
                    model.startBrowsingForWorkspace()
                }
            }
            .padding(.top, 32)
            .frame(maxWidth: 560)

            Spacer(minLength: 0)

            Label("Pairing uses an encrypted private connection and a code you confirm on both devices.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .padding(36)
    }

    private func choiceCard(
        title: String,
        detail: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(systemImage: systemImage, tint: isPrimary ? .accentColor : .secondary, size: 38)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isPrimary ? "create-workspace" : "join-workspace")
    }

    // MARK: Discovery

    private var discovery: some View {
        VStack(spacing: 18) {
            PageHeader(
                title: "Nearby Workspaces",
                detail: "Choose the Mac that is showing “Pair New Mac”."
            ) {
                ProgressView().controlSize(.small)
            }

            Group {
                if model.candidates.isEmpty {
                    ContentUnavailableView {
                        Label("Looking for Macs", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Make sure both Macs are awake, on the same Wi-Fi network, and running UniSpace.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.candidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Label("Connect through Tailscale", systemImage: "network")
                    .font(.headline)
                Text("Enter the other Mac’s MagicDNS name or Tailscale IP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("macbook.tailnet.ts.net or 100.x.x.x", text: $directAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectDirectly)
                        .accessibilityIdentifier("tailscale-address")
                    Button("Connect", action: connectDirectly)
                        .buttonStyle(.borderedProminent)
                        .disabled(directAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .card()

            HStack {
                Spacer()
                Button("Cancel") { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.pageInset)
        .frame(maxWidth: Metrics.contentWidth)
    }

    private func connectDirectly() {
        model.joinDirectly(address: directAddress)
    }

    private func candidateRow(_ candidate: PairingCandidate) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "laptopcomputer", size: 36)
            Text(candidate.name)
                .font(.headline)
            Spacer()
            Button("Join") { model.join(candidate) }
                .buttonStyle(.borderedProminent)
        }
        .card(padding: 12)
    }

    // MARK: Pairing confirmation

    private func confirmation(_ prompt: PairingPrompt) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            IconTile(systemImage: "checkmark.shield.fill", size: 56)
                .padding(.bottom, 18)

            Text("Confirm Pairing")
                .font(.title.bold())

            Text("Check that \(prompt.peer.name) is showing this same code, then approve on both devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 6)

            codeDisplay(prompt.code)
                .padding(.vertical, 26)

            HStack(spacing: 12) {
                Button("Cancel") { model.cancelPairing() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { model.confirmPairing() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

            Spacer(minLength: 0)
        }
        .padding(36)
    }

    /// Renders the pairing code as individual tiles so it is easy to read
    /// aloud and compare across two screens.
    private func codeDisplay(_ code: String) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .frame(width: 46, height: 60)
                    .background(Theme.surfaceStrong, in: .rect(cornerRadius: Metrics.smallRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code")
        .accessibilityValue(code.map(String.init).joined(separator: " "))
    }

    // MARK: Hosting

    private var hosting: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ProgressView()
                .controlSize(.large)
                .padding(.bottom, 20)

            Text("Waiting for another device")
                .font(.title2.bold())

            Text("Keep this screen open, then continue on the Mac or Windows PC you want to add.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 12) {
                pairingGuide(
                    title: "Add another Mac",
                    systemImage: "macbook",
                    instructions: "Open UniSpace, then choose Join Workspace."
                )

                pairingGuide(
                    title: "Add a Windows PC",
                    systemImage: "pc",
                    instructions: "Open Macifier, then choose UniSpace → Set up → Join workspace."
                ) {
                    Link(destination: Self.macifierDownloadURL) {
                        Label("Download Macifier", systemImage: "arrow.up.right.square")
                            .font(.callout.weight(.semibold))
                    }
                    .accessibilityIdentifier("download-macifier")
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 22)

            if let address = model.tailnetAddresses.first {
                VStack(spacing: 7) {
                    Text("Tailscale address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(address.host)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address.host, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Tailscale address")
                    }
                }
                .card()
                .frame(maxWidth: 380)
                .padding(.top, 14)
            } else {
                Text("Tailscale was not detected. Nearby LAN pairing is still available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }

            Button("Cancel") { model.cancelPairing() }
                .controlSize(.large)
                .padding(.top, 24)
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)
        }
        .padding(36)
    }

    private func pairingGuide(
        title: String,
        systemImage: String,
        instructions: String
    ) -> some View {
        pairingGuide(
            title: title,
            systemImage: systemImage,
            instructions: instructions,
            accessory: { EmptyView() }
        )
    }

    private func pairingGuide(
        title: String,
        systemImage: String,
        instructions: String,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .card(padding: 14)
    }

    /// A soft accent wash so the pre-workspace screens feel distinct from the
    /// configured app.
    private var backdrop: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.0)],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }
}
