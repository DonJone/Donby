import SwiftUI

/// High-performance fractional progress bar with zero GeometryReader layout invalidation.
public struct FractionalProgressBar: View {
    public var fraction: Double
    public var color: Color
    public var height: CGFloat = 3.0
    public var trackColor: Color = Color.white.opacity(0.28)

    public init(
        fraction: Double,
        color: Color,
        height: CGFloat = 3.0,
        trackColor: Color = Color.white.opacity(0.28)
    ) {
        self.fraction = fraction
        self.color = color
        self.height = height
        self.trackColor = trackColor
    }

    public init(
        fraction: Double,
        theme: DonbyTheme,
        onDarkOverlay: Bool = true,
        height: CGFloat = 3.0
    ) {
        self.fraction = fraction
        self.color = onDarkOverlay ? theme.overlayAccentColor : theme.accentColor
        self.height = height
        self.trackColor = onDarkOverlay
            ? Color.white.opacity(0.32)
            : (theme.isLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.18))
    }

    public var body: some View {
        Capsule()
            .fill(trackColor)
            .overlay(
                Capsule()
                    .fill(color)
                    .scaleEffect(x: CGFloat(max(0.0, min(1.0, fraction))), y: 1.0, anchor: .leading)
            )
            .clipShape(Capsule())
            .frame(height: height)
    }
}

/// Smoked dark glass badge for watched checkmarks matching media card overlays.
public struct DonbyWatchedBadgeView: View {
    public var size: CGFloat = 19

    public init(size: CGFloat = 19) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(DonbyGlassPalette.smokedOverlayFill)
            Circle()
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
            Image(systemName: "checkmark")
                .font(.system(size: max(8.5, size * 0.47), weight: .bold))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .frame(width: size, height: size)
    }
}

/// Smoked dark glass badge for downloaded / downloading state matching media card pills.
public struct DonbyDownloadedBadgePill: View {
    public let text: String
    public let isCompleted: Bool
    public let accentColor: Color
    public var fontSize: CGFloat = 9.5

    public init(text: String, isCompleted: Bool, accentColor: Color, fontSize: CGFloat = 9.5) {
        self.text = text
        self.isCompleted = isCompleted
        self.accentColor = accentColor
        self.fontSize = fontSize
    }

    public var body: some View {
        let symbolTint = isCompleted ? Color.white.opacity(0.95) : accentColor
        let borderTint = isCompleted ? DonbyGlassPalette.smokedOverlayBorder : accentColor.opacity(0.45)
        HStack(spacing: 3.5) {
            Image(systemName: isCompleted ? "checkmark" : "arrow.down")
                .font(.system(size: max(8.0, fontSize - 1.0), weight: .bold))
                .foregroundStyle(symbolTint)
            Text(text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(DonbyGlassPalette.smokedOverlayFill)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderTint, lineWidth: 0.7)
        )
    }
}

/// Consolidated capsule tag / status pill supporting neutral, accent, smoked, and semantic tones.
public struct DonbyStatusPill: View {
    public enum Tone: Equatable, Sendable {
        case neutral
        case accent
        case smoked
        case success
        case warning
        case error
    }

    @Environment(\.donbyTheme) private var theme
    public let text: String
    public var systemImage: String? = nil
    public var tone: Tone = .neutral
    public var fontSize: CGFloat = 10.5

    public init(
        text: String,
        systemImage: String? = nil,
        tone: Tone = .neutral,
        fontSize: CGFloat = 10.5
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.fontSize = fontSize
    }

    private var foregroundColor: Color {
        switch tone {
        case .neutral: return theme.primaryText
        case .accent: return theme.accentTextColor
        case .smoked: return Color.white.opacity(0.95)
        case .success: return theme.semanticSuccessColor
        case .warning: return theme.semanticWarningColor
        case .error: return theme.semanticErrorColor
        }
    }

    private var fillColor: Color {
        switch tone {
        case .neutral: return theme.cardBackground
        case .accent: return theme.accentColor
        case .smoked: return DonbyGlassPalette.smokedOverlayFill
        case .success: return theme.semanticSuccessColor.opacity(0.14)
        case .warning: return theme.semanticWarningColor.opacity(0.14)
        case .error: return theme.semanticErrorColor.opacity(0.14)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: return theme.separator
        case .accent: return Color.clear
        case .smoked: return DonbyGlassPalette.smokedOverlayBorder
        case .success: return theme.semanticSuccessColor.opacity(0.35)
        case .warning: return theme.semanticWarningColor.opacity(0.35)
        case .error: return theme.semanticErrorColor.opacity(0.35)
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: max(8.5, fontSize - 1), weight: .bold))
            }
            Text(text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(fillColor))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.65)
        )
    }
}

/// Value-type payload for `DonbyToastBanner`.
public struct DonbyToastPayload: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let icon: String
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        icon: String = "checkmark.circle.fill",
        isError: Bool = false
    ) {
        self.id = id
        self.text = text
        self.icon = icon
        self.isError = isError
    }
}

/// Floating pill toast banner with Light / Dark contrast parity and semantic error accent.
public struct DonbyToastBanner: View {
    @Environment(\.donbyTheme) private var theme
    public let toast: DonbyToastPayload
    public var isLightModeOverride: Bool? = nil

    public init(toast: DonbyToastPayload, isLightMode: Bool? = nil) {
        self.toast = toast
        self.isLightModeOverride = isLightMode
    }

    public var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode

        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    toast.isError
                        ? theme.semanticErrorColor
                        : (isLight ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color.white.opacity(0.92))
                )

            Text(toast.text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9.5)
        .background(
            Capsule(style: .continuous)
                .fill(isLight ? Color.white.opacity(0.98) : Color(red: 0.08, green: 0.085, blue: 0.105).opacity(0.94))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.10), lineWidth: 0.65)
        )
        .shadow(
            color: isLight ? Color.black.opacity(0.14) : Color.black.opacity(0.50),
            radius: isLight ? 10 : 14,
            y: isLight ? 4 : 6
        )
    }
}
