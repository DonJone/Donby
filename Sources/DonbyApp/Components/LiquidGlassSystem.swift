import SwiftUI
import AppKit
import DonbyCore

// MARK: - Apple Liquid Glass Design System (Authentic Multi-Layer Optical Refraction)

public enum DonbyGlassPalette {
    /// Deep Space Black cinema canvas
    public static let canvasBlack = Color(red: 0.043, green: 0.046, blue: 0.056)
    /// SenPlayer-inspired Light Mode canvas
    public static let canvasLight = Color(red: 0.945, green: 0.948, blue: 0.960)
    public static let smokedBacking = Color(red: 0.020, green: 0.024, blue: 0.036)

    public static func canvas(isLight: Bool) -> Color {
        isLight ? canvasLight : canvasBlack
    }

    public static func sidebar(isLight: Bool) -> Color {
        isLight ? Color(red: 0.92, green: 0.925, blue: 0.94) : Color(red: 0.075, green: 0.080, blue: 0.095)
    }

    public static func cardBackground(isLight: Bool) -> Color {
        isLight ? Color.white.opacity(0.85) : Color(red: 0.09, green: 0.095, blue: 0.11)
    }

    public static func primaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.10, green: 0.10, blue: 0.12) : Color.white
    }

    public static func secondaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.42, green: 0.42, blue: 0.46) : Color(white: 0.60)
    }

    public static func tertiaryText(isLight: Bool) -> Color {
        isLight ? Color(red: 0.58, green: 0.58, blue: 0.62) : Color(white: 0.42)
    }

    public static func separator(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }
}

/// Optical Visual Effect View for sidebar translucency and desktop-bleed
public struct DonbyVisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .sidebar
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    public init(material: NSVisualEffectView.Material = .sidebar, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

public struct DonbyBackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var alpha: CGFloat = 0.45

    public init(material: NSVisualEffectView.Material = .hudWindow, alpha: CGFloat = 0.45) {
        self.material = material
        self.alpha = alpha
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.alphaValue = alpha
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.alphaValue = alpha
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Groups nearby Liquid Glass controls into a shared WindowServer refraction & batching field on macOS 26+
public struct DonbyGlassContainer<Content: View>: View {
    public var spacing: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

private struct DonbyLiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color?
    let interactive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        let isLight = (colorScheme == .light)
        content
            .background(
                ZStack {
                    if let tint {
                        Capsule(style: .continuous)
                            .fill(tint)
                    } else if isLight {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.94 : 0.88))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tint != nil ? Color.white.opacity(0.18) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
                        lineWidth: 0.65
                    )
            )
            .shadow(
                color: tint != nil
                    ? tint!.opacity(isHovered ? 0.35 : 0.20)
                    : (isLight ? Color.black.opacity(isHovered ? 0.08 : 0.04) : Color.black.opacity(isHovered ? 0.25 : 0.15)),
                radius: isHovered ? 5 : 2.5,
                y: isHovered ? 2 : 1
            )
    }
}

private struct DonbyLiquidGlassRectModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        let isLight = (colorScheme == .light)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    if let tint {
                        shape.fill(tint)
                    } else if isLight {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(isHovered ? 0.94 : 0.88))
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                    }
                }
                .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    tint != nil ? Color.white.opacity(0.18) : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(isHovered ? 0.16 : 0.10)),
                    lineWidth: 0.65
                )
            )
            .shadow(
                color: tint != nil
                    ? tint!.opacity(isHovered ? 0.35 : 0.20)
                    : (isLight ? Color.black.opacity(isHovered ? 0.08 : 0.04) : Color.black.opacity(isHovered ? 0.25 : 0.15)),
                radius: isHovered ? 5 : 2.5,
                y: isHovered ? 2 : 1
            )
    }
}

public extension View {
    func donbyLiquidGlassCapsule(tint: Color? = nil, interactive: Bool = false, isHovered: Bool = false) -> some View {
        modifier(DonbyLiquidGlassCapsuleModifier(tint: tint, interactive: interactive, isHovered: isHovered))
    }

    func donbyLiquidGlassRect(cornerRadius: CGFloat = 15, tint: Color? = nil, interactive: Bool = false, isHovered: Bool = false) -> some View {
        modifier(DonbyLiquidGlassRectModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive, isHovered: isHovered))
    }
}

public struct DonbyLiquidGlassRoundedSurface: View {
    public var cornerRadius: CGFloat = 14
    public var tint: Color? = nil
    public var isHovered: Bool = false

    public init(cornerRadius: CGFloat = 14, tint: Color? = nil, isHovered: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.isHovered = isHovered
    }

    public var body: some View {
        Color.clear
            .donbyLiquidGlassRect(cornerRadius: cornerRadius, tint: tint, interactive: false, isHovered: isHovered)
    }
}

public struct DonbyLiquidGlassCapsuleSurface: View {
    public var tint: Color? = nil
    public var isHovered: Bool = false

    public init(tint: Color? = nil, isHovered: Bool = false) {
        self.tint = tint
        self.isHovered = isHovered
    }

    public var body: some View {
        Color.clear
            .donbyLiquidGlassCapsule(tint: tint, interactive: false, isHovered: isHovered)
    }
}

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

public struct LiquidGlassCircleButton: View {
    @Environment(\.colorScheme) private var colorScheme
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

/// Sculpted Liquid Glass circular button accepting a custom geometric Canvas vector icon
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

/// Sculpted Liquid Glass circular Menu button with unified physical optics matching LiquidGlassCircleButton
public struct LiquidGlassCircleMenu<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public let systemImage: String
    public var iconColor: Color? = nil
    public var size: CGFloat = 38
    public var tooltip: String = ""
    @ViewBuilder public let menuContent: () -> MenuItems

    @State private var isHovered: Bool = false

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

    private var effectiveIconColor: Color {
        if let iconColor { return iconColor }
        return Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    public var body: some View {
        ZStack {
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

            // Transparent Menu trigger on top to open menu with zero layout offset
            Menu {
                menuContent()
            } label: {
                Color.white.opacity(0.0001)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

/// Sculpted Liquid Glass selector card (`资源版本` / `音轨选择` / `主字幕`) replacing stock grey NSPopUpButton
public struct LiquidGlassSelectorCard<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public let title: String
    public let icon: String
    public let valueText: String
    public var badgeText: String? = nil
    public let accentColor: Color
    public var badgeForegroundColor: Color = .white
    @ViewBuilder public let menuItems: () -> MenuItems

    @State private var isHovered: Bool = false

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
        self.accentColor = accentColor
        self.badgeForegroundColor = badgeForegroundColor
        self.menuItems = menuItems
    }

    public var body: some View {
        Menu {
            menuItems()
        } label: {
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
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .donbyLiquidGlassRect(cornerRadius: 15, tint: nil, interactive: true, isHovered: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

/// Smoked dark glass badge for watched checkmarks matching media card overlays
public struct DonbyWatchedBadgeView: View {
    public var size: CGFloat = 19

    public init(size: CGFloat = 19) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.64))
            Circle()
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
            Image(systemName: "checkmark")
                .font(.system(size: max(8.5, size * 0.47), weight: .bold))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .frame(width: size, height: size)
    }
}

/// Smoked dark glass badge for downloaded / downloading state matching media card pills
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
        let borderTint = isCompleted ? Color.white.opacity(0.24) : accentColor.opacity(0.45)
        HStack(spacing: 4) {
            DownloadVectorIcon(
                state: isCompleted ? .completed : .idle,
                size: max(9.5, fontSize + 0.5),
                color: symbolTint
            )
            Text(text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Color.black.opacity(0.64))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderTint, lineWidth: 0.7)
        )
    }
}
