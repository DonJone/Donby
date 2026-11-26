import SwiftUI

/// Sculpted Liquid Glass capsule action button.
public struct LiquidGlassCapsuleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    public let title: String
    public let systemImage: String
    public var tint: Color? = nil
    public var textColorOverride: Color? = nil
    public var progressFraction: Double = 0
    public var horizontalPadding: CGFloat = 22
    public var verticalPadding: CGFloat = 10.5
    public var fontSize: CGFloat = 14
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String,
        tint: Color? = nil,
        textColorOverride: Color? = nil,
        progressFraction: Double = 0,
        horizontalPadding: CGFloat = 22,
        verticalPadding: CGFloat = 10.5,
        fontSize: CGFloat = 14,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.textColorOverride = textColorOverride
        self.progressFraction = progressFraction
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.fontSize = fontSize
        self.action = action
    }

    private var textColor: Color {
        if let textColorOverride {
            return textColorOverride
        }
        if tint != nil {
            if tint == .white {
                return Color(red: 0.10, green: 0.10, blue: 0.12)
            }
            return .white
        }
        return Color(red: 0.10, green: 0.10, blue: 0.12)
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if let tint {
                    Capsule(style: .continuous).fill(tint)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))

                            if progressFraction > 0 {
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.08))
                                    .frame(width: geo.size.width * min(1.0, max(0.0, progressFraction)))
                            }
                        }
                    }
                    .clipShape(Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)
                    )
                    .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0.13), radius: isHovered ? 8 : 5, y: 3)
                }

                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 0.5, weight: .bold))
                    Text(title)
                        .font(.system(size: fontSize, weight: .bold))
                }
                .foregroundStyle(textColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .fixedSize()
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Sculpted Liquid Glass circular icon button.
public struct LiquidGlassCircleButton: View {
    public let systemImage: String
    public var iconColor: Color? = nil
    public var size: CGFloat = 38
    public var tooltip: String = ""
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        systemImage: String,
        iconColor: Color? = nil,
        size: CGFloat = 38,
        tooltip: String = "",
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.size = size
        self.tooltip = tooltip
        self.action = action
    }

    private var effectiveIconColor: Color {
        if let iconColor { return iconColor }
        return Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))
                    .shadow(color: Color.black.opacity(isHovered ? 0.20 : 0.11), radius: isHovered ? 6 : 4, y: 2)

                Circle()
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)

                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(effectiveIconColor)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Sculpted Liquid Glass circular button accepting a custom geometric Canvas vector icon.
public struct LiquidGlassVectorCircleButton<Icon: View>: View {
    public var size: CGFloat = 38
    public var tooltip: String = ""
    public let action: () -> Void
    @ViewBuilder public let icon: () -> Icon

    @State private var isHovered: Bool = false

    public init(
        size: CGFloat = 38,
        tooltip: String = "",
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.size = size
        self.tooltip = tooltip
        self.action = action
        self.icon = icon
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 1.0 : 0.95))
                    .shadow(color: Color.black.opacity(isHovered ? 0.20 : 0.11), radius: isHovered ? 6 : 4, y: 2)

                Circle()
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.65)

                icon()
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Pure SwiftUI Toolbar Button accepting any custom vector icon content (0 native bezel).
public struct ToolbarVectorButton<Icon: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public var tooltip: String = ""
    public var isActive: Bool = false
    public let action: () -> Void
    @ViewBuilder public let icon: (Bool) -> Icon

    @State private var isHovered: Bool = false

    public init(
        tooltip: String = "",
        isActive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping (Bool) -> Icon
    ) {
        self.tooltip = tooltip
        self.isActive = isActive
        self.action = action
        self.icon = icon
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                icon(isHovered)
            }
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(colorScheme == .light ? Color.white : Color(white: 0.16))
                    .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.22), radius: (isHovered || isActive) ? 4 : 2, y: 1)
            )
            .overlay(
                Circle()
                    .strokeBorder(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Circular/pill SF Symbol chrome for detached-hover toolbar Menus.
public struct DonbyToolbarCircleView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let systemName: String
    public var showChevron: Bool = false

    public init(systemName: String, showChevron: Bool = false) {
        self.systemName = systemName
        self.showChevron = showChevron
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(white: 0.90))
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(colorScheme == .light ? Color(red: 0.40, green: 0.40, blue: 0.44) : Color(white: 0.65))
            }
        }
        .frame(width: showChevron ? 42 : 32, height: 32)
        .background(
            Capsule()
                .fill(colorScheme == .light ? Color.white : Color(white: 0.16))
                .shadow(color: Color.black.opacity(colorScheme == .light ? 0.05 : 0.22), radius: 2, y: 1)
        )
        .overlay(
            Capsule()
                .strokeBorder(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }
}

/// Standard primary action button for forms, sheets, and dialogs (replaces `.borderedProminent`).
public struct DonbyPrimaryActionButton: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public var systemImage: String? = nil
    public var isLoading: Bool = false
    public var isDisabled: Bool = false
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accentTextColor)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(theme.accentTextColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control + 1, style: .continuous)
                    .fill(theme.accentColor.opacity(isDisabled ? 0.45 : (isHovered ? 0.90 : 1.0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control + 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .onHover { isHovered = $0 }
    }
}

/// Standard secondary action button for cancel/dismiss/neutral actions in forms and sheets.
public struct DonbySecondaryActionButton: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public var systemImage: String? = nil
    public var isDisabled: Bool = false
    public let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control + 1, style: .continuous)
                    .fill(isHovered ? DonbyGlassPalette.hoverFill(isLight: theme.isLightMode) : (theme.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control + 1, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: DonbyDesignTokens.Stroke.standard)
            )
            .contentShape(RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control + 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}
