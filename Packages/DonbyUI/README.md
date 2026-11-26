# DonbyUI

`DonbyUI` is a standalone, zero-business-dependency macOS 14+ SwiftUI / AppKit component library extracted from Donby's Liquid Glass design system.

## Features

- **Zero Business Dependencies**: Completely decoupled from `AppState`, `DonbyCore`, and `DonbyNetwork`.
- **Theme Environment (`DonbyTheme`)**: Supports Light Mode, Dark Mode, all 9 canonical Donby accent presets, custom RGB overrides, and automatic Monochrome contrast adaptation (including `overlayAccentColor` on dark media scrims).
- **Non-Blue Native Replacement Controls**: Replaces macOS system-blue `.checkbox`, `.switch`, `.segmented`, `.radioGroup`, `.borderedProminent`, `.roundedBorder`, and `NSSlider` with theme-faithful controls.
- **Liquid Glass Surfaces & Detached-Hover Menus**: Includes `donbyLiquidGlassCapsule`, `donbyLiquidGlassRect`, `DonbyMenuHoverBox`, `LiquidGlassCircleMenu`, and `LiquidGlassSelectorCard`.
- **Standard Containers & Feedback**: Provides `DonbySheetContainer`, `DonbySettingsCard`, `DonbySettingsRow`, `DonbySidebarTabRow`, `DonbySelectableRow`, `DonbyStatusPill`, `DonbyToastBanner`, `DonbyEmptyStateView`, `DonbyLoadingStateView`, and 13 `Canvas`-drawn geometric vector icons.

## Installation (Swift Package Manager)

### Local Path Dependency

```swift
dependencies: [
    .package(path: "../Donby/Packages/DonbyUI")
]
```

And add `"DonbyUI"` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["DonbyUI"]
)
```

## Quick Start

Inject `DonbyTheme` at your root view using `.donbyTheme(...)`:

```swift
import SwiftUI
import DonbyUI

struct RootView: View {
    @State private var theme = DonbyTheme(isLightMode: true, accentPreset: .monochrome)

    var body: some View {
        VStack(spacing: 16) {
            DonbySettingsSectionHeader(
                title: "外观与主题",
                subtitle: "统一浅色/深色画布与强调色"
            )

            DonbySettingsCard {
                DonbySettingsRow(title: "启用极简模式") {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .toggleStyle(DonbySwitchToggleStyle())
                }
            }
        }
        .padding(24)
        .background(theme.canvas)
        .donbyTheme(theme)
    }
}
```

## Directory Structure

| Directory | Contents |
| :--- | :--- |
| `Sources/DonbyUI/Tokens/` | `DonbyTheme`, `DonbyRGB`, `DonbyAccentPreset`, `DonbyAppearanceMode`, `DonbyDesignTokens`, `DonbyGlassPalette` |
| `Sources/DonbyUI/Glass/` | `DonbyVisualEffectView`, `DonbyGlassContainer`, `donbyLiquidGlassCapsule`, `donbyLiquidGlassRect`, `DonbyMenuHoverBox` |
| `Sources/DonbyUI/Controls/` | `LiquidGlassCapsuleButton`, `LiquidGlassCircleButton`, `LiquidGlassCircleMenu`, `LiquidGlassSelectorCard`, `ToolbarVectorButton`, `DonbyPrimaryActionButton`, `DonbySecondaryActionButton`, `DonbySegmentedControl`, `DonbyCheckboxToggleStyle`, `DonbySwitchToggleStyle`, `DonbyRadioOptionRow`, `DonbySlider`, `donbyFlatTextField`, `DonbySearchPillField` |
| `Sources/DonbyUI/Feedback/` | `FractionalProgressBar`, `DonbyWatchedBadgeView`, `DonbyDownloadedBadgePill`, `DonbyStatusPill`, `DonbyToastPayload`, `DonbyToastBanner` |
| `Sources/DonbyUI/Containers/` | `DonbySettingsSectionHeader`, `DonbySettingsCard`, `DonbySettingsRow`, `DonbySidebarTabRow`, `DonbySelectableRow`, `DonbySheetContainer`, `PlayerDrawerGlassCard`, `PlayerDrawerRowBackground`, `DonbyEmptyStateView`, `DonbyLoadingStateView` |
| `Sources/DonbyUI/Icons/` | 13 geometric `Canvas`-drawn vector icons (`RouteSwitchVectorIcon`, `RefreshVectorIcon`, `DownloadVectorIcon`, etc.) |

## Build and Test

On macOS Command Line Tools (CLT) environments, run:

```zsh
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
swift test --package-path Packages/DonbyUI --build-system native --sdk "$SDK_PATH" \
  -Xswiftc -F -Xswiftc "$CLT_FW" -Xlinker -F -Xlinker "$CLT_FW" -Xlinker -rpath -Xlinker "$CLT_FW" \
  --disable-xctest
```
