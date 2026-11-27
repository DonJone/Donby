# Player Sub-Map: HUD, Overlays, Drawers & Controls

> Last synced: `v2.1.5`. Parent: [player/INDEX.md](INDEX.md). Covers `PlayerView.swift`, `PlayerOverlays.swift`, `PlayerView+HUD.swift`, `PlayerView+Drawers.swift`, `PlayerSubtitleStyleDrawerView.swift`, `PlayerControls.swift`, `PlayerHUDTelemetryStores.swift`.

## 1. Component Responsibilities
- `PlayerView.swift`: Root `PlayerView` shell holding non-observable `@State autoHideBox` & `@State telemetryBox` (zero root `@StateObject` telemetry subscription so hidden HUD renders at `0 Hz`), `init(session:)`, dynamic `resolvedServer` lookup from `appState.servers`, `DKMetalVideoView` (`onFirstFrameRendered` + `onRenderDiagnostic` `[Render]` logging, `effectiveSubtitleOcclusionHeight` including `PlayerSkipBannerView` and paused HUD lift, non-`@State` `subtitleStyleRevision` posting `DonbyMetalRequestPausedSubtitleRedraw`), `PlayerHostWindowFinder`, single `keyMonitor` (with `.eventTracking`, `hostWindow`, `sheetParent`, and `NSTextView` guards plus layered `ESC`), `mouseMonitor`, `showControlsAndResetTimer()`, `syncVisiblePlaybackStateFromBox()`, `adjustVolume()`.
- `PlayerControls.swift`: `PlayerDrawerTab`, `TracksDrawerSection`, `PlayerAutoHideBox` (holding `healthPolicy`, `lastRecordedPosition`, hover/drag flags, `hostWindow`, coalesced seek task, and hidden-HUD live positions), `PlayerHostWindowFinder`, `OpeningPlayerBox`, `MiniVolumeSlider` (leaf draft volume state), `PlayerConsoleIconButton`, `PlayerCircleMenu`, `PlayerTimelineScrubberView` (hover timestamp preview).
- `PlayerHUDTelemetryStores.swift`: Narrow `ObservableObject` slices (`PlayerTimelineClockStore`, `PlayerWireSpeedStore`, `PlayerMediaStatsStore`), compatibility `PlayerHUDTelemetry` (observed only by leaf `PlayerBufferingOverlayHostView` and `PlayerMediaInfoDrawerContentView`), non-observable `PlayerTelemetryBox` with track-option snapshot caches, and `PlayerMediaSpecFormatter`.
- `PlayerOverlays.swift`: Stateless overlays:
  - `PlayerLoadingOverlayView`: Startup loading pill (`"正在加载..."` + Cancel); stays visible until `DKMetalVideoView.onFirstFrameRendered` sets `hasRenderedFirstFrame = true` (prevents black-screen flash between `dk_open` and first presented frame).
  - `PlayerBufferingOverlayView`: Delayed rebuffer pill (`"正在缓冲..."` + live MB/s); only appears after `>= 0.48s` of continuous stall so brief micro-stalls do not flash UI chrome.
  - `PlayerErrorOverlayView`: Failure card with Retry, Switch Line, Open Logs, Exit actions.
  - `PlayerSkipBannerView`: Floating intro/outro skip pill anchored above `bottomControlBar`.
- `PlayerView+HUD.swift`: `topOSDBar` (`PlayerTopSpeedView` leaf observer, `DonbyPlayerCompanion.makeTopBarControls`), `cachedAudioOptions`/`cachedSubtitleOptions`, and `bottomControlBar` isolating 4Hz `PlayerTimelineClockSectionView` (owning leaf `isScrubbing`/`scrubTime` draft state and `displayedTime`-based remaining time) from transport controls (first/last episode disabled state), `PlayerSpecBadgeHostView` (`PlayerMediaStatsStore` leaf), `PlayerDecoderCircleMenu` (`PlayerMediaStatsStore` leaf), and the remaining `PlayerCircleMenu` popups without `AnyView` wrappers.
- `PlayerView+Drawers.swift`: `rightDrawerPanel(tab:)` (`.playlist` with `LazyVStack`, `.tracks` 2-section segmented pill `轨道` | `样式与对齐` via `PlayerDrawerSegmentedPill`, `.mediaInfo`, `.watchParty`).
- `PlayerSubtitleStyleDrawerView.swift`: Standalone `View` owning `@State private var showMoreSubtitleOptions` and live-preview `draftScale`/`draftVerticalPos` (calling `onLivePreviewStyle` during drag and committing on `onEditingChanged(false)`).

## 2. Critical UI Invariants (DO NOT BREAK)
1. **Menu Flicker Prevention (`v1.4.7`, `v1.4.15`)**:
   - Keep `progressTimer` (`0.25s`) and `embySyncTimer` (`10.0s`) on `RunLoop` mode `.default` (NEVER `.common`, which fires during macOS `NSMenu` `.eventTracking` and flickers open menus).
   - Keep `RunLoop.current.currentMode == .eventTracking` guard inside `showControlsAndResetTimer()`.
   - Store high-frequency mouse-move timestamps, auto-hide tasks, and hidden-HUD live positions in non-observable `PlayerAutoHideBox`.
2. **Full-Area Single-Click Menu Hit-Testing (`v1.4.22`)**:
   - In `PlayerCircleMenu` and drawer selectors, render visual chrome outside `Menu`'s `label:` behind a transparent `Menu` overlay using `.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)` with explicit `.frame` + `.contentShape(...)` (NEVER `.menuStyle(.borderlessButton)`).
3. **Always-Dark Cinema Glass Hygiene (`v1.4.37`)**:
   - NEVER use `.fill(.ultraThinMaterial)` inside `Player/` (macOS `NSVisualEffectView` inherits `.aqua` in Light Mode despite `.environment(\.colorScheme, .dark)`). Always use deterministic dark cinema glass fills (`Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.88...0.92)`), and keep `DonbyApp` switching root window `preferredColorScheme` to `.dark` during active playback.
   - Always use custom non-blue controls (`DonbySlider`, `DonbySwitchToggleStyle`, `PlayerDrawerSegmentedPill`) — never native macOS system-blue controls.
