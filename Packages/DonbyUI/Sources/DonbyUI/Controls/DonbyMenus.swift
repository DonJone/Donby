import SwiftUI

private struct LiquidGlassCircleMenuVisual: View {
    let systemImage: String
    let iconColor: Color?
    let size: CGFloat
    let hoverBox: DonbyMenuHoverBox
    @State private var isHovered: Bool = false

    private var effectiveIconColor: Color {
        if let iconColor { return iconColor }
        return Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    var body: some View {
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
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onAppear {
            hoverBox.onHoverChange = { isHovered = $0 }
            isHovered = hoverBox.isHovered
        }
    }
}

/// Sculpted Liquid Glass circular Menu button using the detached-hover menu pattern.
public struct LiquidGlassCircleMenu<MenuItems: View>: View {
    public let systemImage: String
    public var iconColor: Color? = nil
    public var size: CGFloat = 38
    public var tooltip: String = ""
    @ViewBuilder public let menuContent: () -> MenuItems
    @State private var hoverBox = DonbyMenuHoverBox()

    public init(
        systemImage: String,
        iconColor: Color? = nil,
        size: CGFloat = 38,
        tooltip: String = "",
        @ViewBuilder menuContent: @escaping () -> MenuItems
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.size = size
        self.tooltip = tooltip
        self.menuContent = menuContent
    }

    public var body: some View {
        ZStack {
            LiquidGlassCircleMenuVisual(
                systemImage: systemImage,
                iconColor: iconColor,
                size: size,
                hoverBox: hoverBox
            )
            .allowsHitTesting(false)

            Menu {
                menuContent()
            } label: {
                Color.clear
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onHover { hoverBox.setHovered($0) }
        }
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .help(tooltip)
    }
}

private struct LiquidGlassSelectorCardVisual: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let valueText: String
    let badgeText: String?
    let accentColor: Color
    let badgeForegroundColor: Color
    let hoverBox: DonbyMenuHoverBox
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accentColor.opacity(0.32), accentColor.opacity(0.10)],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 26
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(accentColor.opacity(0.50), lineWidth: 0.75)
                    )
                    .frame(width: 33, height: 33)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colorScheme == .light ? Color(red: 0.44, green: 0.44, blue: 0.48) : Color.white.opacity(0.66))
                    if let badgeText, !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(badgeForegroundColor)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(accentColor.opacity(0.82))
                            .clipShape(Capsule())
                    }
                }

                Text(valueText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colorScheme == .light ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.40, green: 0.40, blue: 0.44) : Color.white.opacity(isHovered ? 0.92 : 0.58))
                .padding(.trailing, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .donbyLiquidGlassRect(cornerRadius: 15, tint: nil, interactive: true, isHovered: isHovered)
        .onAppear {
            hoverBox.onHoverChange = { isHovered = $0 }
            isHovered = hoverBox.isHovered
        }
    }
}

/// Sculpted Liquid Glass selector card replacing stock grey NSPopUpButton.
public struct LiquidGlassSelectorCard<MenuItems: View>: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public let icon: String
    public let valueText: String
    public var badgeText: String? = nil
    public let accentColorOverride: Color?
    public var badgeForegroundColorOverride: Color?
    @ViewBuilder public let menuItems: () -> MenuItems
    @State private var hoverBox = DonbyMenuHoverBox()

    public init(
        title: String,
        icon: String,
        valueText: String,
        badgeText: String? = nil,
        accentColor: Color,
        badgeForegroundColor: Color = .white,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.title = title
        self.icon = icon
        self.valueText = valueText
        self.badgeText = badgeText
        self.accentColorOverride = accentColor
        self.badgeForegroundColorOverride = badgeForegroundColor
        self.menuItems = menuItems
    }

    public init(
        title: String,
        icon: String,
        valueText: String,
        badgeText: String? = nil,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.title = title
        self.icon = icon
        self.valueText = valueText
        self.badgeText = badgeText
        self.accentColorOverride = nil
        self.badgeForegroundColorOverride = nil
        self.menuItems = menuItems
    }

    public var body: some View {
        let effectiveAccent = accentColorOverride ?? theme.accentColor
        let effectiveBadgeText = badgeForegroundColorOverride ?? theme.accentTextColor

        ZStack {
            LiquidGlassSelectorCardVisual(
                title: title,
                icon: icon,
                valueText: valueText,
                badgeText: badgeText,
                accentColor: effectiveAccent,
                badgeForegroundColor: effectiveBadgeText,
                hoverBox: hoverBox
            )
            .allowsHitTesting(false)
        }
        .overlay {
            Menu {
                menuItems()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onHover { hoverBox.setHovered($0) }
        }
    }
}
