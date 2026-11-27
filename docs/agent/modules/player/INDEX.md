# Module Map: Player Surface & Playback UI (`Sources/DonbyApp/Player/*`)

> Last synced: `v2.1.2`. Load this index for any task inside `Sources/DonbyApp/Player/`, then load ONLY the relevant sub-doc below.

## 1. Sub-Doc Routing

| If your task involves... | Read Next | Source Files |
| :--- | :--- | :--- |
| HUD bars, overlays, dropdown menus, menu flicker, right drawer, subtitle style panel, controls | [hud-and-drawers.md](hud-and-drawers.md) | `PlayerView.swift`, `PlayerOverlays.swift`, `PlayerView+HUD.swift`, `PlayerView+Drawers.swift`, `PlayerSubtitleStyleDrawerView.swift`, `PlayerControls.swift` |
| Native kernel open/stop/seek, Turbo handle setup & C-ABI callbacks, progress/sync timers, health recovery, episode prefetch/switch, Watch Party/Danmu companion | [playback-and-lifecycle.md](playback-and-lifecycle.md) | `PlayerView+PlaybackEngine.swift`, `PlayerView+TurboSetup.swift`, `PlayerView+LifecycleAndSession.swift` |
| FFmpeg/Emby track mapping, audio/subtitle switching, external subtitles, kernel subtitle style config, AI auto-alignment & undo | [subtitles-and-tracks.md](subtitles-and-tracks.md) | `PlayerView+TrackSelection.swift`, `PlayerView+SubtitlesAndAlignment.swift` |

## 2. File Inventory (`Sources/DonbyApp/Player/`, 11 files)
- `PlayerView.swift` — `PlayerView` stored properties, `init(session:)`, `body` shell, gesture/`NSEvent` monitor wiring, `showControlsAndResetTimer()`, `syncVisiblePlaybackStateFromBox()`, `adjustVolume()`.
- `PlayerControls.swift` — `PlayerDrawerTab`, `TracksDrawerSection`, `SubtitleAlignUndoState`, `PlayerSubtitleSelection`, track option models, `PlayerAutoHideBox`, `OpeningPlayerBox`, `MiniVolumeSlider`, `PlayerConsoleIconButton`, `PlayerCircleMenu`, `PlayerTimelineScrubberView`.
- `PlayerOverlays.swift` — stateless overlays: `PlayerLoadingOverlayView`, `PlayerBufferingOverlayView`, `PlayerErrorOverlayView`, `PlayerSkipBannerView`.
- `PlayerView+HUD.swift` — `topBarTitleString`, `topOSDBar`, `playerSpecBadge` + `spec*String`, `bottomControlBar`, 5 circular dropdown menus (`audio`, `subtitle`, `decoder`, `speed`, `more`).
- `PlayerView+Drawers.swift` — `rightDrawerPanel(tab:)`, drawer chrome helpers, `PlayerDrawerSegmentedPill`, `.playlist`, `.tracks` (track-picker tab), `.mediaInfo`, `.watchParty`, `osdInfoRow`.
- `PlayerSubtitleStyleDrawerView.swift` — standalone `.tracks` -> `"样式与对齐"` view (owns `@State private var showMoreSubtitleOptions`, AI alignment buttons, delay steppers, style sliders).
- `PlayerView+PlaybackEngine.swift` — file-private `dkTurbo*CB` C-ABI callbacks, `handleProgressTimerTick()` (live `TurboStreamByteHandle.currentWireSpeedMBs` refresh including `isWaitingForSeekOrBuffer` overlay without falling back to local AVIO cache read speed), `startNativeKernelPlayback`, `releasePlaybackNetworkPriority`, `stopNativeKernel`, `togglePlayPause`, `seekRelative`, `seekTo`, `queryKernelChapters`, `cString(from:)`.
- `PlayerView+TurboSetup.swift` — `resolvedTurboPrefetchChunks`, `prepareTurboPlaybackHandle` (wiring `TurboStreamByteHandle`, `DonbyDownloadManager.beginPlaybackNetworkPriority`, `NetworkRouteWarmStore` 302 lookup, and 403/404/410 redirect invalidation), `computePreOpenTrackHints`, `makeRedirectStoreHandler`, and `makeRedirectInvalidateHandler`.
- `PlayerView+TrackSelection.swift` — `embyAudioStreams`, `embySubtitleStreams`, `resolvedAudioOptions`, `resolvedSubtitleOptions`, `queryKernelTracks`, primary/secondary audio & subtitle selection.
- `PlayerView+SubtitlesAndAlignment.swift` — remote/local external subtitle loading, `resolvedDualAnchorMode`, `makeKernelSubtitleStyleConfig`, `applyKernelSubtitleStyle`, `formatSubtitleDelay`, `snapshotSubtitleIntervals`, AI voice/dual-subtitle auto-alignment, undo & time-scale reset.
- `PlayerView+LifecycleAndSession.swift` — `handleEmbySyncTimerTick()`, `prefetchNextEpisodeIfNearEnd()` (resolving via `PlaybackIntentCoordinator` + micro-staging next-episode head/Cues/intro-skip landing when `bufferedAhead >= 12s`), `evaluateIntroOutroSkipWindow()`, `exportRedactedDiagnostics()`, `playAdjacentEpisode()`, `switchToEpisode()` (`0ms` synchronous fast-cut on prefetched/cached resources), `toggleFullScreen()`, `exitPlayer()`, `configureAndBindCompanionIfNeeded()`, `watchPartyDrawerContent`, `saveCurrentWatchProgress()`, `formatTime()`.

## 3. Cross-Cutting Player Invariants
1. **SwiftUI `@State` & `init(session:)` Anchoring**: `_currentItem`, `_currentResource`, `_selectedAudioIdx`, `_selectedSubIdx`, and `_explicitSubtitleOff` are initialized via `State(initialValue:)` in `PlayerView.init(session:)` and must stay in `PlayerView.swift`.
2. **No `deinit` on `View` Structs**: `mouseMonitor`, `keyMonitor`, `autoHideBox.autoHideTask`, and `stopNativeKernel()` must always be torn down in both `.onDisappear` and `exitPlayer()`.
3. **Extension Isolation Firewall**: Zero `#if canImport(DonbyUHDModule)` or `import DonbyUHDModule` inside `Sources/DonbyApp/Player/`. All Watch Party / Danmu integration routes through `DonbyPlayerCompanionBox` (`DonbyAppExtension.swift`).
