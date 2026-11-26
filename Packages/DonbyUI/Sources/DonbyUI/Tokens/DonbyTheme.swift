import SwiftUI
import AppKit

/// Platform-agnostic RGB color token with SwiftUI, AppKit, CoreGraphics, and hex conversions.
public struct DonbyRGB: Equatable, Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let alpha: Double

    public init(r: Double, g: Double, b: Double, alpha: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.alpha = alpha
    }

    public var color: Color {
        Color(red: r, green: g, blue: b, opacity: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    public var cgColor: CGColor {
        nsColor.cgColor
    }

    public var hexString: String {
        let ri = Int((max(0, min(1, r)) * 255.0).rounded())
        let gi = Int((max(0, min(1, g)) * 255.0).rounded())
        let bi = Int((max(0, min(1, b)) * 255.0).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

/// Appearance mode preference matching Donby's Light / Dark / Auto model.
public enum DonbyAppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case light = "light"
    case dark = "dark"
    case auto = "auto"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "浅色模式 (默认)"
        case .dark: return "深色模式"
        case .auto: return "跟随系统"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }
}

/// Canonical 9 Donby theme accent presets.
public enum DonbyAccentPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleMusicRed = "appleMusicRed"
    case monochrome = "monochrome"
    case blue = "blue"
    case cyan = "cyan"
    case green = "green"
    case purple = "purple"
    case orange = "orange"
    case pink = "pink"
    case indigo = "indigo"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleMusicRed: return "经典音乐红"
        case .monochrome: return "纯黑白极简"
        case .blue: return "经典蓝"
        case .cyan: return "极光青"
        case .green: return "翡翠绿"
        case .purple: return "霓虹紫"
        case .orange: return "活力橙"
        case .pink: return "樱花粉"
        case .indigo: return "深空靛"
        }
    }

    /// Canonical sRGB values synchronized with DonbyCore.ThemeColorPalette.
    public var rgb: DonbyRGB {
        switch self {
        case .appleMusicRed: return DonbyRGB(r: 0.980, g: 0.176, b: 0.282)
        case .monochrome: return DonbyRGB(r: 0.12, g: 0.12, b: 0.14)
        case .blue: return DonbyRGB(r: 0.16, g: 0.49, b: 0.96)
        case .cyan: return DonbyRGB(r: 0.12, g: 0.78, b: 0.92)
        case .green: return DonbyRGB(r: 0.18, g: 0.80, b: 0.45)
        case .purple: return DonbyRGB(r: 0.62, g: 0.36, b: 0.98)
        case .orange: return DonbyRGB(r: 1.0, g: 0.55, b: 0.16)
        case .pink: return DonbyRGB(r: 0.96, g: 0.34, b: 0.58)
        case .indigo: return DonbyRGB(r: 0.38, g: 0.42, b: 0.96)
        }
    }
}

/// Complete, AppState-independent theme configuration for DonbyUI components.
public struct DonbyTheme: Equatable, Sendable {
    public var isLightMode: Bool
    public var accentPreset: DonbyAccentPreset
    public var customAccentRGB: DonbyRGB?

    public init(
        isLightMode: Bool = false,
        accentPreset: DonbyAccentPreset = .appleMusicRed,
        customAccentRGB: DonbyRGB? = nil
    ) {
        self.isLightMode = isLightMode
        self.accentPreset = accentPreset
        self.customAccentRGB = customAccentRGB
    }

    public static let lightMonochrome = DonbyTheme(isLightMode: true, accentPreset: .monochrome)
    public static let darkMonochrome = DonbyTheme(isLightMode: false, accentPreset: .monochrome)
    public static let lightDefault = DonbyTheme(isLightMode: true, accentPreset: .appleMusicRed)
    public static let darkDefault = DonbyTheme(isLightMode: false, accentPreset: .appleMusicRed)

    public var isMonochrome: Bool {
        customAccentRGB == nil && accentPreset == .monochrome
    }

    /// Primary UI accent RGB. Monochrome adapts between near-black in Light Mode and white in Dark Mode.
    public var accentRGB: DonbyRGB {
        if let customAccentRGB {
            return customAccentRGB
        }
        if accentPreset == .monochrome {
            return isLightMode
                ? DonbyRGB(r: 0.12, g: 0.12, b: 0.12)
                : DonbyRGB(r: 1.0, g: 1.0, b: 1.0)
        }
        return accentPreset.rgb
    }

    /// High-contrast foreground RGB rendered on top of `accentRGB` fills.
    public var accentTextRGB: DonbyRGB {
        if isMonochrome && !isLightMode {
            return DonbyRGB(r: 0.0, g: 0.0, b: 0.0)
        }
        return DonbyRGB(r: 1.0, g: 1.0, b: 1.0)
    }

    /// Accent RGB for elements placed on dark media artwork scrims (progress bars, poster favorite icons).
    /// Monochrome always resolves to pure white on dark overlays so Light Mode stays legible.
    public var overlayAccentRGB: DonbyRGB {
        if isMonochrome {
            return DonbyRGB(r: 1.0, g: 1.0, b: 1.0)
        }
        return accentRGB
    }

    public var accentColor: Color { accentRGB.color }
    public var accentTextColor: Color { accentTextRGB.color }
    public var overlayAccentColor: Color { overlayAccentRGB.color }

    /// Semantic feedback colors (kept consistent regardless of active accent preset).
    public var semanticErrorColor: Color { DonbyAccentPreset.appleMusicRed.rgb.color }
    public var semanticSuccessColor: Color { DonbyAccentPreset.green.rgb.color }
    public var semanticWarningColor: Color { DonbyAccentPreset.orange.rgb.color }

    // Surface & text conveniences
    public var canvas: Color { DonbyGlassPalette.canvas(isLight: isLightMode) }
    public var sidebar: Color { DonbyGlassPalette.sidebar(isLight: isLightMode) }
    public var cardBackground: Color { DonbyGlassPalette.cardBackground(isLight: isLightMode) }
    public var primaryText: Color { DonbyGlassPalette.primaryText(isLight: isLightMode) }
    public var secondaryText: Color { DonbyGlassPalette.secondaryText(isLight: isLightMode) }
    public var separator: Color { DonbyGlassPalette.separator(isLight: isLightMode) }
}

private struct DonbyThemeKey: EnvironmentKey {
    static let defaultValue: DonbyTheme = .darkDefault
}

public extension EnvironmentValues {
    var donbyTheme: DonbyTheme {
        get { self[DonbyThemeKey.self] }
        set { self[DonbyThemeKey.self] = newValue }
    }
}

public extension View {
    /// Injects a `DonbyTheme` and aligns `.tint` with the theme's active accent color.
    func donbyTheme(_ theme: DonbyTheme) -> some View {
        self
            .environment(\.donbyTheme, theme)
            .tint(theme.accentColor)
    }
}

/// Canonical spacing, corner radius, stroke, and motion tokens across DonbyUI.
public enum DonbyDesignTokens {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let control: CGFloat = 7
        public static let row: CGFloat = 9
        public static let card: CGFloat = 12
        public static let selector: CGFloat = 15
        public static let sheet: CGFloat = 16
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let standard: CGFloat = 0.65
        public static let active: CGFloat = 0.85
        public static let focus: CGFloat = 1.2
    }

    public enum AnimationToken {
        public static let quick: Animation = .easeOut(duration: 0.14)
        public static let hover: Animation = .easeOut(duration: 0.16)
        public static let springSwitch: Animation = .spring(response: 0.22, dampingFraction: 0.85)
    }
}
