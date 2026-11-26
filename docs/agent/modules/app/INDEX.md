# Module Map: Main App State, Views & Native UI (`Sources/DonbyApp/`)

> Last synced: `v2.0.17`. Load this index for non-player `DonbyApp` tasks, then load ONLY the relevant sub-doc below.
> For player surface/HUD/engine/subtitles (`Sources/DonbyApp/Player/*`), load [modules/player/INDEX.md](../player/INDEX.md).
> For optional UHDNow UI (`Sources/DonbyApp/Modules/UHD/*`), load [modules/uhd-module.md](../uhd-module.md).

## 1. Sub-Doc Routing (43 files across 5 domains)

| If your task involves... | Read Next | Source Files |
| :--- | :--- | :--- |
| App entry, window shell, sidebar/toolbar clamping, `AppState` & extensions, extension bootstrap, log viewer | [state-and-shell.md](state-and-shell.md) | `DonbyApp.swift`, `MainWindowView.swift`, `AppState*.swift` (6), `LogViewerSheet.swift`, `Extensions/DonbyAppExtension.swift` |
| Emby home shelves, carousel swipe, category library grid, `DetailView` `#03` hero strip & seasons/episodes | [home-and-detail.md](home-and-detail.md) | `EmbyMainView.swift`, `MainCarouselView.swift`, `Views/MLibListView.swift`, `DetailView*.swift` (4) |
| 120Hz AppKit `NSCollectionView`/`CALayer` cards, offscreen text/badge caches, artwork cache & loaders | [native-collection-and-artwork.md](native-collection-and-artwork.md) | `Components/Native*.swift` (6), `ArtworkCacheEngine.swift`, `MediaArtworkViews.swift`, `HeroTopEdgeBackdrop.swift`, `MediaCards.swift` |
| Liquid Glass surfaces, detached-hover menus, non-blue theme form controls, brand marks & toolbar icons | [design-system.md](design-system.md) | `Components/LiquidGlassSystem.swift`, `DonbyThemeControls.swift`, `BrandMarks.swift`, `ToolbarIconsAndControls.swift` |
| Server list/config/line picker, Files browser, Settings & updater, Downloads, Search, IPTV, Watch Records | [feature-views.md](feature-views.md) | `ServerViews.swift`, `ServerConfigSheet.swift`, `Views/{FilesModuleView*,SettingsView*,DownloadsView,DownloadRowCards,GlobalSearchView,IPTVModuleView,RecordsView}.swift` |

## 2. Cross-Cutting App Invariants
1. **Extension Isolation Firewall**: Core `DonbyApp` files contain **zero** direct `DonbyUHDModule` imports; `DonbyAppExtensionCenter.installCompiledExtensionsIfNeeded()` in `Extensions/DonbyAppExtension.swift` is the single compile-time bootstrap seam (`#if canImport(DonbyUHDModule) && !DONBY_PURE_BUILD`).
2. **Zero Synchronous Disk Scans in SwiftUI `body`**: Never call `DonbyOfflineLibraryStorage.scanOfflineLibrary`, `DonbyTurboCacheEngine.cachedProgress`, or `NSImage(contentsOf:)` inside SwiftUI `body`; offload to `.task` / `Task.detached`.
3. **Zero Native macOS System-Blue Controls**: Always use custom controls from `Components/DonbyThemeControls.swift` and root `.tint(appState.accentColor)` on `MainWindowView` and sheets.
4. **Version Source of Truth**: All Swift modules read `DonbyAppInfo.version` (`Sources/DonbyCore/AppUpdatePolicies.swift`); never hardcode version strings in `DonbyApp`.
