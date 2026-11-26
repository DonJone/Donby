# DonbyUI Design System Specification

This document defines the canonical visual grammar, color tokens, and engineering invariants for `DonbyUI`. All new views and components must adhere to these rules to prevent visual drift across Light Mode, Dark Mode, and Monochrome themes.

## 1. Design Tokens

### Spacing (`DonbyDesignTokens.Spacing`)
- `xs`: `4pt`
- `sm`: `8pt`
- `md`: `12pt`
- `lg`: `16pt`
- `xl`: `24pt`
- `xxl`: `32pt`

### Corner Radius (`DonbyDesignTokens.Radius`)
- `control`: `7pt` (segmented control inner pill, compact action button at `8pt`)
- `row`: `9pt` (selectable rows, drawer rows, flat text fields, segmented outer track)
- `card`: `12pt` (settings cards, player drawer glass cards)
- `selector`: `15pt` (`LiquidGlassSelectorCard`)
- `sheet`: `16pt` (modal sheets)

### Stroke Weights (`DonbyDesignTokens.Stroke`)
- `hairline`: `0.5pt`
- `standard`: `0.65pt`
- `active`: `0.85pt`
- `focus`: `1.2pt`

### Canvas & Surface Tokens (`DonbyGlassPalette`)
- Light Canvas: `rgb(0.945, 0.948, 0.960)`
- Dark Canvas (Deep Space Black): `rgb(0.043, 0.046, 0.056)`
- Light Card Background: `Color.white.opacity(0.85)`
- Dark Card Background: `rgb(0.09, 0.095, 0.11)`
- Light Primary Text: `rgb(0.10, 0.10, 0.12)`
- Dark Primary Text: `Color.white`
- Light Secondary Text: `rgb(0.42, 0.42, 0.46)`
- Dark Secondary Text: `Color(white: 0.60)`
- Separator: `Color.black.opacity(0.08)` (Light) / `Color.white.opacity(0.08)` (Dark)
- Smoked Media Overlay Fill: `Color.black.opacity(0.64)` with `Color.white.opacity(0.22)` border

## 2. Theme Presets & Monochrome Contrast Rule

`DonbyAccentPreset` defines 9 canonical presets:
1. `appleMusicRed`: `#FA2D48` (`0.980, 0.176, 0.282`)
2. `monochrome`: `#1F1F24` (`0.12, 0.12, 0.14`)
3. `blue`: `#297DF5` (`0.16, 0.49, 0.96`)
4. `cyan`: `#1FC7EB` (`0.12, 0.78, 0.92`)
5. `green`: `#2ECC73` (`0.18, 0.80, 0.45`)
6. `purple`: `#9E5CFA` (`0.62, 0.36, 0.98`)
7. `orange`: `#FF8C29` (`1.0, 0.55, 0.16`)
8. `pink`: `#F55794` (`0.96, 0.34, 0.58`)
9. `indigo`: `#6169F5` (`0.38, 0.42, 0.96`)

### Mandatory Monochrome Contrast Invariant
- **Light Mode + Monochrome**:
  - `accentColor` = `Color(white: 0.12)`
  - `accentTextColor` = `.white`
  - `overlayAccentColor` = `.white` (never dark grey on dark media scrims!)
- **Dark Mode + Monochrome**:
  - `accentColor` = `.white`
  - `accentTextColor` = `.black`
  - `overlayAccentColor` = `.white`
- **All Colored Presets**:
  - `accentColor` = preset RGB
  - `accentTextColor` = `.white`
  - `overlayAccentColor` = `accentColor`

Never hardcode `#FA2D48` (`appleMusicRed`) for decorative accents (titles, stars, hearts, progress bars). Reserve semantic red (`theme.semanticErrorColor`) strictly for error states (`isError == true`, failure badges, validation errors).

## 3. Dark Cinema Glass Hygiene

Never use `.ultraThinMaterial` inside dark-mode branches of Liquid Glass modifiers (`donbyLiquidGlassCapsule`, `donbyLiquidGlassRect`). In macOS Light Mode, `NSVisualEffectView` under `.ultraThinMaterial` can bleed `.aqua` white frost into dark overlays. Use explicit smoked dark fill (`Color(red: 0.11, green: 0.115, blue: 0.135).opacity(...)`) in dark branches.

## 4. Non-Blue Native Control Blacklist

Never use native macOS system-blue controls in DonbyUI or host apps:

| Forbidden Native Pattern | Required DonbyUI Replacement |
| :--- | :--- |
| `.toggleStyle(.checkbox)` | `DonbyCheckboxToggleStyle()` |
| `.toggleStyle(.switch)` | `DonbySwitchToggleStyle()` |
| `.pickerStyle(.segmented)` | `DonbySegmentedControl(...)` |
| `.pickerStyle(.radioGroup)` | `DonbyRadioOptionRow(...)` |
| `.buttonStyle(.borderedProminent)` | `DonbyPrimaryActionButton(...)` or `LiquidGlassCapsuleButton(...)` |
| `.textFieldStyle(.roundedBorder)` | `.donbyFlatTextField(isLight:)` or `DonbySearchPillField(...)` |
| Bare SwiftUI `Slider` | `DonbySlider(...)` |
| Raw `.blue` / `NSColor.controlAccentColor` | `theme.accentColor` |

Every `.buttonStyle(.plain)` button must declare an explicit `.contentShape(...)` matching its hit target.

## 5. Detached-Hover Menu Contract

macOS `NSMenu` strips custom shadows/circles or flickers when SwiftUI re-evaluates `Menu { ... }` on hover. Always use:
1. A non-observable `DonbyMenuHoverBox` bridge.
2. A visual layer marked `.allowsHitTesting(false)`.
3. A transparent `Menu` overlay with `.menuStyle(.button)`, `.buttonStyle(.plain)`, `.menuIndicator(.hidden)`, explicit `.frame`, and `.contentShape(...)`.

See `LiquidGlassCircleMenu` and `LiquidGlassSelectorCard` in `DonbyButtonsAndMenus.swift` for canonical implementations.

## 6. Component Selection Matrix

- **Modal Dialog / Inspector**: `DonbySheetContainer` + `DonbyPrimaryActionButton` / `DonbySecondaryActionButton`
- **Settings Page**: `DonbySettingsSectionHeader` + `DonbySettingsCard` + `DonbySettingsRow` + `DonbySidebarTabRow`
- **Selectable List (Servers / Lines / Tracks)**: `DonbySelectableRow`
- **Media / Overlay Progress**: `FractionalProgressBar(fraction:theme:onDarkOverlay:)`
- **Status / Metadata Tag**: `DonbyStatusPill` / `DonbyWatchedBadgeView` / `DonbyDownloadedBadgePill`
- **Transient Notification**: `DonbyToastBanner` with `DonbyToastPayload`
- **Empty / Loading Views**: `DonbyEmptyStateView` / `DonbyLoadingStateView`
