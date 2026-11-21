# Module Map: App, Player HUD & Native UI (`DonbyApp`)

> Last synced: `v1.4.18`. Load this doc for `PlayerView`, `AppState`, `DetailView`, 120Hz native collection views, artwork caching, Liquid Glass UI, and module views.

## 1. File Inventory & Core Symbols
- **App Entry & Global State**:
  - `Sources/DonbyApp/DonbyApp.swift` (~250L) — `AppDelegate` (auto-detaches residual mounted DMGs on launch, single-instance hygiene, `donby://` URL scheme), `DonbyApp`.
  - `Sources/DonbyApp/AppState.swift` (~2637L) — `@MainActor` central state: server configs, Emby/UHD clients, playback session lifecycle, watch history (max 300, deduplicated), search history, per-season skip prefs (`SeasonSkipPreference`), `ServerHomeCacheStore`.
  - `Sources/DonbyApp/MainWindowView.swift` (~450L) — sidebar navigation, `AppUpdatePromptSheet`.
- **Player Surface & Controls**:
  - `Sources/DonbyApp/PlayerView.swift` (~3540L) — playback orchestration: `computePreOpenTrackHints`, `makeKernelSubtitleStyleConfig`, `applySubtitleOptionOnStartup`, `prefetchNextEpisodeIfNearEnd`, `isSettlingSeek` guard (`2.5s`), loading pill (`hasRenderedFirstFrame`), delayed rebuffer pill (`>= 0.48s` `"正在缓冲..."`), track switching (`activeTurboHandle?.wakeWaitingReads()`), health recovery (`PlaybackHealthPolicy`), chapter/OP/ED skipping, Level-2 subtitle menu `字音自动对齐` / `双字幕自动对齐` / `撤销`, and decluttered 2-section `.tracks` drawer (`轨道` | `样式与对齐`).
  - `Sources/DonbyApp/Player/PlayerControls.swift` (~319L) — `PlayerTimelineScrubberView`, `PlayerDrawerTab`, `OpeningPlayerBox`, `PlayerAutoHideBox`, track option models.
- **High-FPS Browse & Artwork Pipeline**:
  - `Sources/DonbyApp/Components/NativeCardLayers.swift` (~1928L) — AppKit `NSCollectionView` / `CALayer` cells (`InteractiveCollectionView`, `ScrollHoverGate`, `NativeCardLayerCache`, `CardTextBitmapCache`).
  - `Sources/DonbyApp/Components/NativeEmbyHomeView.swift` (~696L) & `NativePosterGridView.swift` (~571L) — 120Hz ProMotion scrolling shelves & poster grids.
  - `Sources/DonbyApp/Components/ArtworkComponents.swift` (~1600L) — `ScrollActivityTracker`, `ArtworkImageCache` (512 MiB disk cache, 410 MiB prune target, ImageIO hardware downsampling), `ArtworkDownloadCoordinator` (request coalescing), `CGImageLoadCoordinator`.
  - `Sources/DonbyApp/Components/LiquidGlassSystem.swift` (~674L) & `BrandIconsAndToolbar.swift` (~1285L) & `MediaCards.swift` (~536L).
- **Feature Views**:
  - `DetailView.swift` (~1761L), `EmbyMainView.swift` (~907L), `MainCarouselView.swift` (~403L), `ServerViews.swift` (~997L), `LogViewerSheet.swift` (~345L).
  - `Views/DownloadsView.swift` (~954L), `Views/FilesModuleView.swift` (~1224L), `Views/GlobalSearchView.swift` (~509L), `Views/IPTVModuleView.swift` (~405L), `Views/RecordsView.swift` (~293L), `Views/SettingsView.swift` (~965L).

## 2. Key Player UX State Machine (`PlayerView.swift`)
- **Startup Loading Pill**: Remains visible until `DKMetalVideoView.onFirstFrameRendered` sets `hasRenderedFirstFrame = true` (prevents black-screen flicker between `dk_open` and first presented frame).
- **Seek Settling Guard (`isSettlingSeek`)**: `2.5s` window after seek so timeline scrubber does not snap back to stale pre-seek PTS while decoder flushes.
- **Delayed Rebuffer Pill**: Only shows `"正在缓冲..."` after `>= 0.48s` of continuous rebuffering so brief micro-stalls do not flash UI chrome.
- **Prewarm & Next-Episode Prefetch**: `DetailView` / `PlayerView` prewarm redirect/playback info and prefetch next episode near end.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **120Hz Scroll Hygiene**: Never do synchronous disk I/O, offscreen shadows, or SwiftUI layout thrashing inside `NativeEmbyHomeView` / `NativePosterGridView` scroll paths; respect `ScrollActivityTracker.isScrolling` and `ScrollHoverGate`. Keep `HorizontalShelfScrollView` horizontal scroller hidden via `tile()` and avoid forced scroll-snapping (feels unnatural on macOS trackpad).
2. **Hit-Testing in Native Collection Views**: Preserve `InteractiveCollectionView` click/hover hit-testing (`v1.3.20` regression fix).
3. **Hero Backdrop & ClearLogo Hygiene**: In `DetailView.heroHeaderSection`, keep the upper ~46% of the backdrop completely clear and vivid (`.saturation(1.10).contrast(1.04)`), then dissolve smoothly in a single direction into `canvasCol` (`0.46 -> 1.0`) without dark-to-light muddy bands or double-blur ghosting. In `ClearLogoHeaderView`, never use white-halo glow on dark fallback text, and suppress duplicate text subtitle underneath a loaded movie/series ClearLogo.
4. **Card Interaction, Badge & Copy Consistency**: Clicking any poster or landscape card always enters `DetailView` (no center hover play button triggering immediate playback). Cards omit resolution badges and rating stars; downloaded badges use unified monochrome smoked-glass pill + white `checkmark` with `"已下载"` copy (never `"已离线下载"`). Sidebar places concrete servers at top above `搜索 -> 服务器 -> 文件 -> 记录 -> 下载 -> IPTV -> 设置`.
5. **Detail Preload Play-Button Binding (`v1.4.4`)**: `DetailView.effectivePlayButtonStartSeconds` binds background preloading directly to the Play button's exact start position (resume position, or automatic intro-skip landing position when starting at 0s) and re-evaluates whenever target/source/start position updates.
6. **Menu Flicker & Custom Chrome Preservation (`v1.4.7`, `v1.4.15`)**: Keep `PlayerView` timers (`progressTimer`, `embySyncTimer`) on `.default` RunLoop mode (never `.common`, which fires during macOS `NSMenu` `.eventTracking`), store high-frequency mouse-move/auto-hide state in non-observable `PlayerAutoHideBox`, and for styled macOS `Menu` buttons (`LiquidGlassCircleMenu`, `LiquidGlassSelectorCard`, `PlayerCircleMenu`, secondary subtitle picker) ALWAYS render visual chrome (circles, shadows, `.donbyLiquidGlassRect`) **outside** `Menu`'s `label:` behind a transparent `Menu` overlay driven by non-observable `DonbyMenuHoverBox`—macOS `NSPopUpButtonCell` strips Shapes/backgrounds placed inside `Menu`'s `label:`.
7. **Version Source of Truth**: All Swift modules read `DonbyAppInfo.version` (`Sources/DonbyCore/AppUpdatePolicies.swift`); when bumping versions, update `build_app.sh`, `DonbyAppInfo.fallbackVersion`, and `docs/agent/INDEX.md`.
8. **Log Redaction**: `AppState` `媒体流解析成功` log must keep stream URL host/query redacted.
