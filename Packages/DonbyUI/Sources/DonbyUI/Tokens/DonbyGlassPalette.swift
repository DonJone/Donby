import SwiftUI

/// Surface, text, and border color tokens for Donby's Deep Space Black and Light Mode canvases.
public enum DonbyGlassPalette {
    /// Deep Space Black cinema canvas
    public static let canvasBlack = Color(red: 0.043, green: 0.046, blue: 0.056)
    /// Light Mode canvas
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

    public static func hoverFill(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.035) : Color.white.opacity(0.07)
    }

    /// Smoked dark glass surface for media artwork overlays
    public static let smokedOverlayFill = Color.black.opacity(0.64)
    public static let smokedOverlayBorder = Color.white.opacity(0.22)

    /// Dark cinema drawer surface (always dark regardless of app Light/Dark mode)
    public static let darkCinemaCardFill = Color.white.opacity(0.055)
    public static let darkCinemaCardBorder = Color.white.opacity(0.09)
}
