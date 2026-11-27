import SwiftUI

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
                        .frame(maxWidth: expandsEqually ? .infinity : nil, minHeight: 24)
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
            .frame(minWidth: 24, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : [.isButton])
        .accessibilityValue(configuration.isOn ? "已选中" : "未选中")
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
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : [.isButton])
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
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

    private var formattedAccessibilityValue: String {
        if let step, step >= 1.0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
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
                        let clamped = min(range.upperBound, max(range.lowerBound, next))
                        if abs(clamped - value) > 1e-9 {
                            value = clamped
                        }
                    }
                    .onEnded { _ in
                        if isDragging {
                            isDragging = false
                            onEditingChanged?(false)
                        }
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(formattedAccessibilityValue)
        .accessibilityAdjustableAction { direction in
            let delta = step ?? max((range.upperBound - range.lowerBound) / 20.0, 0.01)
            let next: Double
            switch direction {
            case .increment:
                next = min(range.upperBound, value + delta)
            case .decrement:
                next = max(range.lowerBound, value - delta)
            @unknown default:
                return
            }
            if abs(next - value) > 1e-9 {
                onEditingChanged?(true)
                value = next
                onEditingChanged?(false)
            }
        }
    }
}

private struct DonbyFlatTextFieldModifier: ViewModifier {
    let isLight: Bool
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .donbyFocusEffectDisabled()
            .focused($isFocused)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused
                            ? (isLight ? Color.black.opacity(0.42) : Color.white.opacity(0.48))
                            : DonbyGlassPalette.separator(isLight: isLight),
                        lineWidth: isFocused ? 1.2 : 0.65
                    )
            )
    }
}

public extension View {
    /// Clean flat Donby text field styling without macOS default bright-blue focus rings.
    func donbyFlatTextField(isLight: Bool, cornerRadius: CGFloat = 9, horizontalPadding: CGFloat = 11, verticalPadding: CGFloat = 8) -> some View {
        self.modifier(
            DonbyFlatTextFieldModifier(
                isLight: isLight,
                cornerRadius: cornerRadius,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }

    @ViewBuilder
    func donbyFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func donbyOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
