import SwiftUI
import UniSpaceDomain

/// The display topology page: a direct-manipulation canvas plus a readable,
/// keyboard-accessible list of the connections it produces.
struct DisplaysView: View {
    @ObservedObject var model: AppModel
    @State private var resetToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
            PageHeader(
                title: "Display Topology",
                detail: "Arrange displays the way they sit on your desk. Offline devices stay in place and are bypassed until they reconnect."
            ) {
                Button("Reset Layout") { resetToken += 1 }
                    .controlSize(.small)
                    .disabled(model.allDisplays.count < 2)
            }

            if model.allDisplays.count < 2 {
                ContentUnavailableView {
                    Label("Nothing to arrange yet", systemImage: "rectangle.3.group")
                } description: {
                    Text("Pair another device and its displays will appear here, ready to be placed next to this one.")
                } actions: {
                    if model.isLocalController {
                        Button("Pair New Device") { model.startHostingPairing() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                topologyLegend
                TopologyCanvas(model: model, resetToken: resetToken)
                    .frame(minHeight: 300)
                ConnectionList(model: model)
            }
        }
        .padding(Metrics.pageInset)
    }

    private var topologyLegend: some View {
        HStack(spacing: 16) {
            DisplayLegendItem(title: "This Mac", color: .accentColor)
            DisplayLegendItem(title: "Online", color: .green)
            DisplayLegendItem(title: "Offline", color: .secondary)
            Spacer(minLength: 8)
            Label("Drag cards together to connect edges", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DisplayLegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Canvas

private struct TopologyCanvas: View {
    @ObservedObject var model: AppModel
    let resetToken: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var unitPositions: [DisplayID: CGPoint] = [:]
    @State private var dragging: DisplayID?
    @State private var dragTranslation: CGSize = .zero
    @State private var snapTarget: DisplayID?
    @State private var hovered: DisplayID?

    private let cardSize = CGSize(width: 132, height: 84)
    private let snapDistance: Double = 250

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Theme.canvas)

                dotGrid(size)
                linkLayer(size)
                snapPreview(size)

                ForEach(model.allDisplays) { display in
                    card(display)
                        .position(point(for: display.id, in: size))
                        .zIndex(dragging == display.id ? 1 : 0)
                        .gesture(dragGesture(for: display, in: size))
                        .onHover { hovered = $0 ? display.id : (hovered == display.id ? nil : hovered) }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
            .clipShape(.rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .onAppear { seedPositions(replacingAll: false) }
            .onChange(of: model.allDisplays.map(\.id)) { _, _ in seedPositions(replacingAll: false) }
            .onChange(of: resetToken) { _, _ in
                withAnimation(reduceMotion ? nil : .unispace) { seedPositions(replacingAll: true) }
            }
        }
    }

    // MARK: Layers

    private func dotGrid(_ size: CGSize) -> some View {
        Canvas { context, _ in
            let spacing: Double = 24
            let dot: Double = 1.5
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(0.07)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }

    private func linkLayer(_ size: CGSize) -> some View {
        Canvas { context, _ in
            for link in uniqueLinks {
                let from = anchor(link.source, in: size)
                let to = anchor(link.destination, in: size)
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(
                    path,
                    with: .color(.accentColor.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                for endpoint in [from, to] {
                    let rect = CGRect(x: endpoint.x - 3.5, y: endpoint.y - 3.5, width: 7, height: 7)
                    context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func snapPreview(_ size: CGSize) -> some View {
        if let dragging, let snapTarget {
            Canvas { context, _ in
                var path = Path()
                path.move(to: point(for: dragging, in: size))
                path.addLine(to: point(for: snapTarget, in: size))
                context.stroke(
                    path,
                    with: .color(.accentColor.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5])
                )
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Card

    private func card(_ display: DisplayDescriptor) -> some View {
        let isLocal = display.deviceID == model.localDeviceID
        let isOnline = model.onlineDeviceIDs.contains(display.deviceID)
        let isDragging = dragging == display.id
        let isTarget = snapTarget == display.id
        let tint: Color = isLocal ? .accentColor : (isOnline ? .green : .secondary)

        return VStack(spacing: 5) {
            Image(systemName: isLocal ? "laptopcomputer" : "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
            VStack(spacing: 1) {
                Text(deviceName(display.deviceID))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(display.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(
            RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                .fill(isLocal ? Color.accentColor.opacity(0.16) : Theme.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                .strokeBorder(isTarget ? Color.accentColor : Theme.hairline, lineWidth: isTarget ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(9)
                .accessibilityHidden(true)
        }
        .shadow(
            color: .black.opacity(isDragging ? 0.28 : 0.12),
            radius: isDragging ? 12 : 3,
            y: isDragging ? 6 : 1
        )
        .scaleEffect(isDragging ? 1.04 : (hovered == display.id ? 1.015 : 1))
        .opacity(isOnline ? 1 : 0.72)
        .animation(reduceMotion ? nil : .unispace, value: isDragging)
        .animation(reduceMotion ? nil : .unispace, value: isTarget)
        .animation(reduceMotion ? nil : .unispace, value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(deviceName(display.deviceID)), \(display.name), \(isOnline ? "online" : "offline")"
        )
        .accessibilityHint("Drag next to a display on another device to connect them.")
    }

    // MARK: Gesture

    private func dragGesture(for display: DisplayDescriptor, in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragging != display.id {
                    dragging = display.id
                }
                dragTranslation = value.translation
                snapTarget = nearestCandidate(to: display, in: size)?.id
            }
            .onEnded { _ in
                // Resolve both the resting point and the snap target while the
                // drag translation is still applied, then commit. Writing the
                // position first would make `point(for:)` add the translation
                // on top of the already-translated position.
                let resting = point(for: display.id, in: size)
                let target = nearestCandidate(to: display, in: size)

                dragging = nil
                dragTranslation = .zero
                snapTarget = nil

                if size.width > 0, size.height > 0 {
                    unitPositions[display.id] = CGPoint(
                        x: resting.x / size.width,
                        y: resting.y / size.height
                    )
                }
                if let target {
                    connect(display, to: target, in: size)
                }
            }
    }

    private func connect(_ source: DisplayDescriptor, to target: DisplayDescriptor, in size: CGSize) {
        let sourcePoint = point(for: source.id, in: size)
        let targetPoint = point(for: target.id, in: size)
        let dx = targetPoint.x - sourcePoint.x
        let dy = targetPoint.y - sourcePoint.y
        let sourceEdge: DisplayEdge = abs(dx) >= abs(dy)
            ? (dx >= 0 ? .right : .left)
            : (dy >= 0 ? .bottom : .top)
        model.connect(
            DisplayEndpoint(displayID: source.id, edge: sourceEdge),
            to: DisplayEndpoint(displayID: target.id, edge: sourceEdge.opposite)
        )
    }

    /// The closest display belonging to a *different* Mac, within snapping range.
    private func nearestCandidate(to source: DisplayDescriptor, in size: CGSize) -> DisplayDescriptor? {
        let origin = point(for: source.id, in: size)
        return model.allDisplays
            .filter { $0.deviceID != source.deviceID }
            .map { ($0, distance(origin, point(for: $0.id, in: size))) }
            .filter { $0.1 < snapDistance }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: Geometry

    private func point(for id: DisplayID, in size: CGSize) -> CGPoint {
        let unit = unitPositions[id] ?? CGPoint(x: 0.5, y: 0.5)
        var result = CGPoint(x: unit.x * size.width, y: unit.y * size.height)
        if dragging == id {
            result.x += dragTranslation.width
            result.y += dragTranslation.height
        }
        return clamped(result, in: size)
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let insetX = cardSize.width / 2 + 10
        let insetY = cardSize.height / 2 + 10
        return CGPoint(
            x: min(max(point.x, insetX), max(size.width - insetX, insetX)),
            y: min(max(point.y, insetY), max(size.height - insetY, insetY))
        )
    }

    private func anchor(_ endpoint: DisplayEndpoint, in size: CGSize) -> CGPoint {
        let center = point(for: endpoint.displayID, in: size)
        switch endpoint.edge {
        case .left: return CGPoint(x: center.x - cardSize.width / 2, y: center.y)
        case .right: return CGPoint(x: center.x + cardSize.width / 2, y: center.y)
        case .top: return CGPoint(x: center.x, y: center.y - cardSize.height / 2)
        case .bottom: return CGPoint(x: center.x, y: center.y + cardSize.height / 2)
        }
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    // MARK: State

    /// Lays displays out grouped by Mac — one row per Mac. Existing positions
    /// survive unless a reset was requested, so the canvas never jumps while a
    /// peer's workspace update arrives.
    private func seedPositions(replacingAll: Bool) {
        let devices = model.devices.filter { !$0.displays.isEmpty }
        guard !devices.isEmpty else { return }
        var result = replacingAll ? [:] : unitPositions
        let rowCount = devices.count
        for (row, device) in devices.enumerated() {
            let columnCount = device.displays.count
            for (column, display) in device.displays.enumerated() {
                guard replacingAll || result[display.id] == nil else { continue }
                result[display.id] = CGPoint(
                    x: Double(column + 1) / Double(columnCount + 1),
                    y: Double(row + 1) / Double(rowCount + 1)
                )
            }
        }
        let live = Set(model.allDisplays.map(\.id))
        unitPositions = result.filter { live.contains($0.key) }
    }

    private var uniqueLinks: [EdgeLink] {
        guard let links = model.workspace?.topology.links else { return [] }
        return links.filter { $0.source.displayID.description < $0.destination.displayID.description }
    }

    private func deviceName(_ id: DeviceID) -> String {
        model.devices.first { $0.id == id }?.name ?? "Mac"
    }
}

// MARK: - Connection list

private struct ConnectionList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connections", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            if links.isEmpty {
                Label(
                    "No connections yet. Drag one display next to a display on another device.",
                    systemImage: "hand.draw"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        if index > 0 { Divider() }
                        row(link)
                    }
                }
                .card(padding: 0)
            }
        }
    }

    private func row(_ link: EdgeLink) -> some View {
        HStack(spacing: 10) {
            Text(label(for: link.source.displayID))
                .font(.callout)
            Text(link.source.edge.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.left.and.right")
                .font(.caption)
                .foregroundStyle(.tint)
            Text(label(for: link.destination.displayID))
                .font(.callout)
            Text(link.destination.edge.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(role: .destructive) {
                model.disconnect(link.source)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this connection")
            .accessibilityLabel("Remove connection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var links: [EdgeLink] {
        guard let all = model.workspace?.topology.links else { return [] }
        return all.filter { $0.source.displayID.description < $0.destination.displayID.description }
    }

    private func label(for id: DisplayID) -> String {
        guard let display = model.allDisplays.first(where: { $0.id == id }) else { return "Display" }
        let device = model.devices.first { $0.id == display.deviceID }?.name ?? "Mac"
        return "\(device) · \(display.name)"
    }
}
