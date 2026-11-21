import SwiftUI
import AppKit
import DonbyCore

// MARK: - Apple Liquid Glass Design System (Authentic Multi-Layer Optical Refraction)

public enum DonbyGlassPalette {
    /// Deep Space Black cinema canvas
    public static let canvasBlack = Color(red: 0.043, green: 0.046, blue: 0.056)
    /// SenPlayer-inspired Light Mode canvas
    public static let canvasLight = Color(red: 0.945, green: 0.948, blue: 0.960)

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

    public static func separator(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }
}

/// Theme-faithful Donby Liquid Glass segmented control (replaces macOS default blue `.segmented` Picker).
public struct DonbySegmentedControl<Option: Hashable>: View {
    public let options: [Option]
    @Binding public var selection: Option
    public let title: (Option) -> String
    public let isLightMode: Bool
    public let accentColor: Color
    public let accentTextColor: Color
    public var fontSize: CGFloat = 12
    public var horizontalPadding: CGFloat = 11
    public var verticalPadding: CGFloat = 5
    public var expandsEqually: Bool = false

    public init(
        options: [Option],
        selection: Binding<Option>,
        isLightMode: Bool,
        accentColor: Color,
        accentTextColor: Color,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 11,
        verticalPadding: CGFloat = 5,
        expandsEqually: Bool = false,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.expandsEqually = expandsEqually
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { opt in
                let isSelected = (selection == opt)
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = opt
                    }
                } label: {
                    Text(title(opt))
                        .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(
                            isSelected
                                ? accentTextColor
                                : DonbyGlassPalette.secondaryText(isLight: isLightMode)
                        )
                        .lineLimit(1)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                        .frame(maxWidth: expandsEqually ? .infinity : nil)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? accentColor : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLightMode), lineWidth: 0.5)
        )
    }
}

/// Theme-faithful Donby Checkbox ToggleStyle (replaces macOS default blue `.checkbox` Toggle).
public struct DonbyCheckboxToggleStyle: ToggleStyle {
    public let isLightMode: Bool
    public let accentColor: Color
    public let accentTextColor: Color

    public init(isLightMode: Bool, accentColor: Color, accentTextColor: Color) {
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(
                            configuration.isOn
                                ? accentColor
                                : (isLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        )
                        .frame(width: 15, height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(
                                    configuration.isOn
                                        ? accentColor
                                        : (isLightMode ? Color.black.opacity(0.18) : Color.white.opacity(0.22)),
                                    lineWidth: 0.85
                                )
                        )

                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(accentTextColor)
                    }
                }

                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Theme-faithful Donby Switch ToggleStyle (replaces macOS default blue `.switch` Toggle).
public struct DonbySwitchToggleStyle: ToggleStyle {
    public let isLightMode: Bool
    public let accentColor: Color
    public let accentTextColor: Color
    public var compact: Bool = false

    public init(isLightMode: Bool, accentColor: Color, accentTextColor: Color, compact: Bool = false) {
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        let trackWidth: CGFloat = compact ? 28 : 34
        let trackHeight: CGFloat = compact ? 16 : 19
        let thumbSize: CGFloat = compact ? 12 : 15
        let thumbOffset: CGFloat = (trackWidth - thumbSize) * 0.5 - 2

        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                configuration.label

                ZStack {
                    Capsule(style: .continuous)
                        .fill(
                            configuration.isOn
                                ? accentColor
                                : (isLightMode ? Color.black.opacity(0.14) : Color.white.opacity(0.18))
                        )
                        .frame(width: trackWidth, height: trackHeight)

                    Circle()
                        .fill(configuration.isOn ? accentTextColor : Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                        .frame(width: thumbSize, height: thumbSize)
                        .offset(x: configuration.isOn ? thumbOffset : -thumbOffset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Theme-faithful Donby Slider (replaces macOS default blue NSSlider track).
public struct DonbySlider: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public var step: Double? = nil
    public let isLightMode: Bool
    public let accentColor: Color
    public var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging: Bool = false

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        isLightMode: Bool,
        accentColor: Color,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(1.0, max(0.0, (value - range.lowerBound) / span))
    }

    public var body: some View {
        GeometryReader { geo in
            let trackWidth = max(1, geo.size.width)
            let thumbDiameter: CGFloat = 13
            let usableWidth = max(1, trackWidth - thumbDiameter)
            let fillWidth = max(thumbDiameter * 0.5, CGFloat(fraction) * usableWidth + thumbDiameter * 0.5)
            let thumbX = CGFloat(fraction) * usableWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(isLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.16))
                    .frame(height: 4)

                Capsule(style: .continuous)
                    .fill(accentColor)
                    .frame(width: fillWidth, height: 4)

                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .strokeBorder(isLightMode ? Color.black.opacity(0.16) : Color.black.opacity(0.28), lineWidth: 0.7)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 0.8)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let ratio = min(1.0, max(0.0, Double((gesture.location.x - thumbDiameter * 0.5) / usableWidth)))
                        var next = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                        if let step, step > 0 {
                            next = (next / step).rounded() * step
                        }
                        value = min(range.upperBound, max(range.lowerBound, next))
                    }
                    .onEnded { _ in
                        if isDragging {
                            isDragging = false
                            onEditingChanged?(false)
                        }
                    }
            )
        }
        .frame(height: 18)
    }
}

public extension View {
    /// Clean flat Donby text field styling without macOS default bright-blue focus rings.
    func donbyFlatTextField(isLight: Bool, cornerRadius: CGFloat = 9, horizontalPadding: CGFloat = 11, verticalPadding: CGFloat = 8) -> some View {
        self
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.65)
            )
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

/// Non-observable hover signal bridge so hovering a Menu trigger updates detached visual chrome
/// without re-evaluating `Menu { menuContent() }` (preserving macOS NSMenu stability & full custom chrome).
public final class DonbyMenuHoverBox {
    private var current: Bool = false
    public var onHoverChange: ((Bool) -> Void)?

    public init() {}

    public func setHovered(_ next: Bool) {
        guard current != next else { return }
        current = next
        onHoverChange?(next)
    }

    public var isHovered: Bool { current }
}

/// Isolated hover chrome for `LiquidGlassCircleMenu` rendered outside `Menu` so macOS never strips its circle/shadow.
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

/// Sculpted Liquid Glass circular Menu button with unified physical optics matching LiquidGlassCircleButton
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

/// Isolated hover chrome for `LiquidGlassSelectorCard` rendered outside `Menu` so macOS never strips Liquid Glass chrome.
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

/// Sculpted Liquid Glass selector card (`资源版本` / `音轨选择` / `主字幕`) replacing stock grey NSPopUpButton
public struct LiquidGlassSelectorCard<MenuItems: View>: View {
    public let title: String
    public let icon: String
    public let valueText: String
    public var badgeText: String? = nil
    public let accentColor: Color
    public var badgeForegroundColor: Color = .white
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
        self.accentColor = accentColor
        self.badgeForegroundColor = badgeForegroundColor
        self.menuItems = menuItems
    }

    public var body: some View {
        ZStack {
            LiquidGlassSelectorCardVisual(
                title: title,
                icon: icon,
                valueText: valueText,
                badgeText: badgeText,
                accentColor: accentColor,
                badgeForegroundColor: badgeForegroundColor,
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
        let borderTint = isCompleted ? Color.white.opacity(0.22) : accentColor.opacity(0.45)
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
        .background(Color.black.opacity(0.64))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderTint, lineWidth: 0.7)
        )
    }
}
