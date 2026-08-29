import SwiftUI

/// Shared visual tokens so every surface in UniSpace lands on the same grid,
/// radius, and contrast ramp.
enum Metrics {
    static let cardRadius: Double = 14
    static let smallRadius: Double = 10
    static let heroRadius: Double = 20

    static let pageInset: Double = 26
    static let stackSpacing: Double = 18
    static let contentWidth: Double = 680
}

enum Theme {
    /// A raised surface that reads correctly in both appearances without
    /// hard-coding either palette.
    static let surface = Color.primary.opacity(0.045)
    static let surfaceStrong = Color.primary.opacity(0.075)
    static let hairline = Color.primary.opacity(0.09)
    static let canvas = Color.primary.opacity(0.028)
}

extension Animation {
    /// The single motion curve used for state changes across the app.
    static let unispace = Animation.smooth(duration: 0.32)
}

// MARK: - Surfaces

extension View {
    /// Wraps content in the standard UniSpace card surface.
    func card(radius: Double = Metrics.cardRadius, padding: Double = 16) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surface, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }

    /// Applies an accent focus ring, used for drag targets in the topology editor.
    func focusRing(_ active: Bool, radius: Double = Metrics.smallRadius) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(active ? 1 : 0)
        )
    }
}

// MARK: - Status pill

struct StatusPill: View {
    enum Tone {
        case accent
        case positive
        case warning
        case neutral

        var color: Color {
            switch self {
            case .accent: .accentColor
            case .positive: .green
            case .warning: .orange
            case .neutral: .secondary
            }
        }
    }

    let title: String
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.22)))
    }
}

// MARK: - Page scaffolding

/// A consistent title/subtitle block for the top of a detail page.
struct PageHeader: View {
    let title: String
    let detail: String
    var accessory: AnyView?

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
        self.accessory = nil
    }

    init(title: String, detail: String, @ViewBuilder accessory: () -> some View) {
        self.title = title
        self.detail = detail
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if let accessory {
                accessory
            }
        }
    }
}

/// A rounded icon tile used in device rows and the setup flow.
struct IconTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: Double = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(tint.opacity(0.2))
            )
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
