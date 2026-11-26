import SwiftUI

/// Theme-faithful Donby segmented control (replaces macOS default blue `.segmented` Picker).
public struct DonbySegmentedControl<Option: Hashable>: View {
    @Environment(\.donbyTheme) private var theme
    public let options: [Option]
    @Binding public var selection: Option
    public let title: (Option) -> String
    public let isLightModeOverride: Bool?
    public let accentColorOverride: Color?
    public let accentTextColorOverride: Color?
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
        self.isLightModeOverride = isLightMode
        self.accentColorOverride = accentColor
        self.accentTextColorOverride = accentTextColor
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.expandsEqually = expandsEqually
        self.title = title
    }

    public init(
        options: [Option],
        selection: Binding<Option>,
        fontSize: CGFloat = 12,
        horizontalPadding: CGFloat = 11,
        verticalPadding: CGFloat = 5,
        expandsEqually: Bool = false,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.isLightModeOverride = nil
        self.accentColorOverride = nil
        self.accentTextColorOverride = nil
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.expandsEqually = expandsEqually
        self.title = title
    }

    public var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        let accent = accentColorOverride ?? theme.accentColor
        let accentText = accentTextColorOverride ?? theme.accentTextColor

        HStack(spacing: 3) {
            ForEach(options, id: \.self) { opt in
                let isSelected = (selection == opt)
                Button {
                    withAnimation(DonbyDesignTokens.AnimationToken.quick) {
                        selection = opt
                    }
                } label: {
                    Text(title(opt))
                        .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(
                            isSelected
                                ? accentText
                                : DonbyGlassPalette.secondaryText(isLight: isLight)
                        )
                        .lineLimit(1)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                        .frame(maxWidth: expandsEqually ? .infinity : nil)
                        .background(
                            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control, style: .continuous)
                                .fill(isSelected ? accent : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
                .fill(isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DonbyDesignTokens.Radius.row, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: DonbyDesignTokens.Stroke.hairline)
        )
    }
}

private struct DonbyCheckboxToggleBody<Label: View>: View {
    @Environment(\.donbyTheme) private var theme
    let isOn: Bool
    let isLightModeOverride: Bool?
    let accentColorOverride: Color?
    let accentTextColorOverride: Color?
    let toggleAction: () -> Void
    let label: Label

    var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        let accent = accentColorOverride ?? theme.accentColor
        let accentText = accentTextColorOverride ?? theme.accentTextColor

        Button(action: toggleAction) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(
                            isOn
                                ? accent
                                : (isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
                        )
                        .frame(width: 15, height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(
                                    isOn
                                        ? accent
                                        : (isLight ? Color.black.opacity(0.18) : Color.white.opacity(0.22)),
                                    lineWidth: DonbyDesignTokens.Stroke.active
                                )
                        )

                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(accentText)
                    }
                }

                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Theme-faithful Donby Checkbox ToggleStyle (replaces macOS default blue `.checkbox` Toggle).
public struct DonbyCheckboxToggleStyle: ToggleStyle {
    public let isLightMode: Bool?
    public let accentColor: Color?
    public let accentTextColor: Color?

    public init(isLightMode: Bool, accentColor: Color, accentTextColor: Color) {
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
    }

    public init() {
        self.isLightMode = nil
        self.accentColor = nil
        self.accentTextColor = nil
    }

    public func makeBody(configuration: Configuration) -> some View {
        DonbyCheckboxToggleBody(
            isOn: configuration.isOn,
            isLightModeOverride: isLightMode,
            accentColorOverride: accentColor,
            accentTextColorOverride: accentTextColor,
            toggleAction: {
                withAnimation(.easeOut(duration: 0.12)) {
                    configuration.isOn.toggle()
                }
            },
            label: configuration.label
        )
    }
}

private struct DonbySwitchToggleBody<Label: View>: View {
    @Environment(\.donbyTheme) private var theme
    let isOn: Bool
    let isLightModeOverride: Bool?
    let accentColorOverride: Color?
    let accentTextColorOverride: Color?
    let compact: Bool
    let toggleAction: () -> Void
    let label: Label

    var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        let accent = accentColorOverride ?? theme.accentColor
        let accentText = accentTextColorOverride ?? theme.accentTextColor
        let trackWidth: CGFloat = compact ? 28 : 34
        let trackHeight: CGFloat = compact ? 16 : 19
        let thumbSize: CGFloat = compact ? 12 : 15
        let thumbOffset: CGFloat = (trackWidth - thumbSize) * 0.5 - 2

        Button(action: toggleAction) {
            HStack(spacing: 8) {
                label

                ZStack {
                    Capsule(style: .continuous)
                        .fill(
                            isOn
                                ? accent
                                : (isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.18))
                        )
                        .frame(width: trackWidth, height: trackHeight)

                    Circle()
                        .fill(isOn ? accentText : Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                        .frame(width: thumbSize, height: thumbSize)
                        .offset(x: isOn ? thumbOffset : -thumbOffset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Theme-faithful Donby Switch ToggleStyle (replaces macOS default blue `.switch` Toggle).
public struct DonbySwitchToggleStyle: ToggleStyle {
    public let isLightMode: Bool?
    public let accentColor: Color?
    public let accentTextColor: Color?
    public var compact: Bool = false

    public init(isLightMode: Bool, accentColor: Color, accentTextColor: Color, compact: Bool = false) {
        self.isLightMode = isLightMode
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
        self.compact = compact
    }

    public init(compact: Bool = false) {
        self.isLightMode = nil
        self.accentColor = nil
        self.accentTextColor = nil
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        DonbySwitchToggleBody(
            isOn: configuration.isOn,
            isLightModeOverride: isLightMode,
            accentColorOverride: accentColor,
            accentTextColorOverride: accentTextColor,
            compact: compact,
            toggleAction: {
                withAnimation(DonbyDesignTokens.AnimationToken.springSwitch) {
                    configuration.isOn.toggle()
                }
            },
            label: configuration.label
        )
    }
}

/// Theme-faithful single-selection radio row (replaces macOS `.radioGroup` Picker).
public struct DonbyRadioOptionRow: View {
    @Environment(\.donbyTheme) private var theme
    public let title: String
    public let isSelected: Bool
    public let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? theme.accentColor : theme.separator, lineWidth: 1.3)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Theme-faithful Donby Slider (replaces macOS default blue NSSlider track).
public struct DonbySlider: View {
    @Environment(\.donbyTheme) private var theme
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public var step: Double? = nil
    public let isLightModeOverride: Bool?
    public let accentColorOverride: Color?
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
        self.isLightModeOverride = isLightMode
        self.accentColorOverride = accentColor
        self.onEditingChanged = onEditingChanged
    }

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.isLightModeOverride = nil
        self.accentColorOverride = nil
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(1.0, max(0.0, (value - range.lowerBound) / span))
    }

    public var body: some View {
        let isLight = isLightModeOverride ?? theme.isLightMode
        let accent = accentColorOverride ?? theme.accentColor

        GeometryReader { geo in
            let trackWidth = max(1, geo.size.width)
            let thumbDiameter: CGFloat = 13
            let usableWidth = max(1, trackWidth - thumbDiameter)
            let fillWidth = max(thumbDiameter * 0.5, CGFloat(fraction) * usableWidth + thumbDiameter * 0.5)
            let thumbX = CGFloat(fraction) * usableWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.16))
                    .frame(height: 4)

                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: fillWidth, height: 4)

                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .strokeBorder(isLight ? Color.black.opacity(0.16) : Color.black.opacity(0.28), lineWidth: 0.7)
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
    func donbyFlatTextField(
        isLight: Bool,
        cornerRadius: CGFloat = 9,
        horizontalPadding: CGFloat = 11,
        verticalPadding: CGFloat = 8
    ) -> some View {
        self
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: DonbyDesignTokens.Stroke.standard)
            )
    }
}

/// Liquid Glass pill search bar without native macOS bezel or blue focus ring.
public struct DonbySearchPillField: View {
    @Environment(\.colorScheme) private var colorScheme
    public let placeholder: String
    @Binding public var text: String
    public var width: CGFloat = 260
    public var onSubmit: (() -> Void)? = nil

    public init(
        placeholder: String = "搜索",
        text: Binding<String>,
        width: CGFloat = 260,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.56))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 13))
                .foregroundStyle(colorScheme == .light ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white)
                .onSubmit {
                    onSubmit?()
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: min(128, width), idealWidth: width, maxWidth: width)
        .frame(height: 34)
        .donbyLiquidGlassCapsule(tint: nil, interactive: false, isHovered: false)
    }
}
