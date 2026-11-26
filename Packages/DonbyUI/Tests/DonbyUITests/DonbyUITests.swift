import Foundation
import Testing
@testable import DonbyUI

@Suite("DonbyUI Tokens and Theme Tests")
struct DonbyUITests {
    @Test("All 9 DonbyAccentPreset values match canonical RGB and hex")
    func accentPresetsMatchCanonicalValues() {
        #expect(DonbyAccentPreset.allCases.count == 9)
        #expect(DonbyAccentPreset.appleMusicRed.rgb.hexString == "#FA2D48")
        #expect(DonbyAccentPreset.monochrome.rgb == DonbyRGB(r: 0.12, g: 0.12, b: 0.14))
        #expect(DonbyAccentPreset.blue.rgb == DonbyRGB(r: 0.16, g: 0.49, b: 0.96))
        #expect(DonbyAccentPreset.cyan.rgb == DonbyRGB(r: 0.12, g: 0.78, b: 0.92))
        #expect(DonbyAccentPreset.green.rgb == DonbyRGB(r: 0.18, g: 0.80, b: 0.45))
        #expect(DonbyAccentPreset.purple.rgb == DonbyRGB(r: 0.62, g: 0.36, b: 0.98))
        #expect(DonbyAccentPreset.orange.rgb == DonbyRGB(r: 1.0, g: 0.55, b: 0.16))
        #expect(DonbyAccentPreset.pink.rgb == DonbyRGB(r: 0.96, g: 0.34, b: 0.58))
        #expect(DonbyAccentPreset.indigo.rgb == DonbyRGB(r: 0.38, g: 0.42, b: 0.96))
    }

    @Test("Monochrome Light, Dark, and Overlay contrast invariants")
    func monochromeContrastInvariants() {
        let lightMono = DonbyTheme.lightMonochrome
        #expect(lightMono.isMonochrome)
        #expect(lightMono.accentRGB == DonbyRGB(r: 0.12, g: 0.12, b: 0.12))
        #expect(lightMono.accentTextRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
        #expect(lightMono.overlayAccentRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
        #expect(lightMono.lightSurfaceAccentRGB == DonbyRGB(r: 0.12, g: 0.12, b: 0.14))

        let darkMono = DonbyTheme.darkMonochrome
        #expect(darkMono.isMonochrome)
        #expect(darkMono.accentRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
        #expect(darkMono.accentTextRGB == DonbyRGB(r: 0.0, g: 0.0, b: 0.0))
        #expect(darkMono.overlayAccentRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
        #expect(darkMono.lightSurfaceAccentRGB == DonbyRGB(r: 0.12, g: 0.12, b: 0.14))

        let colored = DonbyTheme(isLightMode: true, accentPreset: .cyan)
        #expect(!colored.isMonochrome)
        #expect(colored.accentRGB == DonbyAccentPreset.cyan.rgb)
        #expect(colored.accentTextRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
        #expect(colored.overlayAccentRGB == DonbyAccentPreset.cyan.rgb)
        #expect(colored.lightSurfaceAccentRGB == DonbyAccentPreset.cyan.rgb)
    }

    @Test("Custom RGB accent overrides preset and disables monochrome flag")
    func customAccentOverride() {
        let custom = DonbyRGB(r: 0.25, g: 0.50, b: 0.75)
        let theme = DonbyTheme(isLightMode: false, accentPreset: .monochrome, customAccentRGB: custom)
        #expect(!theme.isMonochrome)
        #expect(theme.accentRGB == custom)
        #expect(theme.overlayAccentRGB == custom)
        #expect(theme.accentTextRGB == DonbyRGB(r: 1.0, g: 1.0, b: 1.0))
    }

    @Test("AppearanceMode preferredColorScheme mapping")
    func appearanceModeMapping() {
        #expect(DonbyAppearanceMode.light.preferredColorScheme == .light)
        #expect(DonbyAppearanceMode.dark.preferredColorScheme == .dark)
        #expect(DonbyAppearanceMode.auto.preferredColorScheme == nil)
    }

    @Test("DonbyMenuHoverBox deduplicates hover state and invokes callback")
    func menuHoverBoxDeduplication() {
        let box = DonbyMenuHoverBox()
        var events: [Bool] = []
        box.onHoverChange = { events.append($0) }

        #expect(!box.isHovered)
        box.setHovered(false)
        #expect(events.isEmpty)

        box.setHovered(true)
        box.setHovered(true)
        #expect(box.isHovered)
        #expect(events == [true])

        box.setHovered(false)
        #expect(!box.isHovered)
        #expect(events == [true, false])
    }

    @Test("DonbyToastPayload identity and equatability")
    func toastPayloadIdentityAndEquatability() {
        let fixedID = UUID()
        let a = DonbyToastPayload(id: fixedID, text: "已保存", icon: "checkmark.circle.fill", isError: false)
        let b = DonbyToastPayload(id: fixedID, text: "已保存", icon: "checkmark.circle.fill", isError: false)
        let c = DonbyToastPayload(text: "失败", icon: "exclamationmark.triangle.fill", isError: true)

        #expect(a == b)
        #expect(a != c)
        #expect(c.isError)
    }

    @Test("DonbyGlassPalette separates light and dark canvas colors")
    func glassPaletteContrast() {
        #expect(DonbyGlassPalette.canvas(isLight: true) == DonbyGlassPalette.canvasLight)
        #expect(DonbyGlassPalette.canvas(isLight: false) == DonbyGlassPalette.canvasBlack)
        #expect(DonbyGlassPalette.canvasLight != DonbyGlassPalette.canvasBlack)
        #expect(DonbyGlassPalette.primaryText(isLight: true) != DonbyGlassPalette.primaryText(isLight: false))
    }
}
