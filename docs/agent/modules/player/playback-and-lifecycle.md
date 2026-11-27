# Player Sub-Map: Playback Engine, Timers & Session Lifecycle

> Last synced: `v2.1.5`. Parent: [player/INDEX.md](INDEX.md). Covers `PlayerView+PlaybackEngine.swift`, `PlayerView+TurboSetup.swift`, and `PlayerView+LifecycleAndSession.swift`.

## 1. Native Kernel & Turbo Bridge (`PlayerView+PlaybackEngine.swift` & `PlayerView+TurboSetup.swift`)
- `PlayerView+PlaybackEngine.swift` — C-ABI callbacks, kernel open/stop/seek, 0.25s progress loop, health recovery.
- `PlayerView+TurboSetup.swift` — `resolvedTurboPrefetchChunks`, `prepareTurboPlaybackHandle`, `computePreOpenTrackHints`, `makeRedirectStoreHandler`, `makeRedirectInvalidateHandler`.
- `PlayerView+LifecycleAndSession.swift` — 10s Emby sync, next-episode micro-stage prefetch, intro/outro skip, `0ms` synchronous episode switch/exit, companion & GPU danmu gate (Section 2).
- **C-ABI Callbacks (file-private top-level funcs)**: `dkTurboReadCB`, `dkTurboSeekCB`, `dkTurboAbortCB`, `dkTurboCloseCB` bridge `TurboStreamByteHandle` via `Unmanaged` into `dk_player_open_with_tracks`, paired with `dk_player_attach_stream_bridge` so L1/L2/partial `AVIO` reads execute inside `KernelRust` without crossing into Swift. Keep callbacks as file-private top-level functions (C function pointers cannot capture Swift context).
- **Startup & Open Flow**:
  - `startNativeKernelPlayback(startSeconds:allowWarmCacheRetry:resetHealthPolicy:)` increments `activePlaybackGeneration`, aborts any prior `OpeningPlayerBox`, computes `computePreOpenTrackHints()`, installs `makeRedirectStoreHandler`, acquires `DonbyDownloadManager.beginPlaybackNetworkPriority` & attaches `TurboStreamByteHandle` (with `initialStartSeconds`/`knownDurationSeconds` for speculative resume prefetch) when Turbo is active, opens the Rust kernel on `Task.detached`, applies initial `DKSubtitleStyleConfig`, and queries `queryKernelTracks` + `queryKernelChapters`. `reloadPlaybackWithResolvedServer(at:resetHealthPolicy:)` re-resolves `currentResource` against `resolvedServer` on line switch or retry. `stopNativeKernel()` and non-retrying open failures release the download playback-priority token via `releasePlaybackNetworkPriority()` so background downloads auto-resume immediately. If `open/probe` fails while a warm cached Chunk 0 was present (`allowWarmCacheRetry == true`), it aborts the failed Turbo handle, calls `store.invalidateProbeChunks()`, and auto-retries once cleanly from the network.
  - Every `Task.detached` -> `MainActor.run` callback MUST check `self.activePlaybackGeneration == thisGeneration` to drop stale callbacks after rapid seek/retry/episode switch.
- **0.25s Progress Loop (`handleProgressTimerTick()`)**:
  - **Seek Settling Guard (`isSettlingSeek`)**: `0.75s` window (`abs(newPos - lastSeekCommitTarget) > 0.35`) after seek commit (`lastSeekCommitUptime` / `lastSeekCommitTarget`) so short and long seeks do not snap back to stale pre-seek PTS while the decoder flushes; `seekRelative(_:)` coalesces rapid arrow-key presses over `70ms`.
  - **Stall / Health Policy**: Evaluates `autoHideBox.healthPolicy` (`PlaybackHealthPolicy`) without mutating SwiftUI `@State` (`recover` triggers reconnect at `livePos` with `resetHealthPolicy: false` so `.fail` remains reachable; `fail` surfaces `openingErrorMessage`).
  - **Side Effects**: Calls `evaluateIntroOutroSkipWindow()` (using `currentItemStartPositionSeconds` so episode 2+ auto-skip works), `prefetchNextEpisodeIfNearEnd()`, companion `onProgressTick(...)`, and periodic 5s local watch-progress saves (`autoHideBox.lastRecordedPosition`). Telemetry updates target narrow `telemetryBox` stores (`clock`, `speed`, `mediaStats`), gating HUD and legacy-drawer writes on visibility so hidden-HUD playback keeps `PlayerView.body` at `0 Hz`.

## 2. Session, Episode Switching & Companion (`PlayerView+LifecycleAndSession.swift`)
- `PlayerView+LifecycleAndSession.swift` — 10s Emby sync, next-episode prefetch, intro/outro skip, episode switch/exit, companion & GPU danmu gate:
- **Remote Progress Sync (`handleEmbySyncTimerTick()`)**: 10s timer guarded against opening/error/ended states, routing progress via `DonbyMediaServiceRegistry.shared.provider(for:)` or `EmbyClient.shared.reportPlaybackProgress(...)` using `resolvedServer`.
- **Next-Episode Prefetch & Skip**:
  - `prefetchNextEpisodeIfNearEnd()`: Triggers at `>= max(duration * 0.72, duration - 120)` when next episode is not already downloaded; resolves control-plane resource via `PlaybackIntentCoordinator.shared.resolveAndCacheResource` and, once `liveBufferedAheadSeconds >= 12.0 && !isWaitingForSeekOrBuffer`, micro-stages next-episode head + EOF Cues + auto-intro-skip landing chunks via `startMicroStagePreload`.
  - `evaluateIntroOutroSkipWindow()`: Combines `ChapterSkipDetector` (`kernelChapters`) with per-season `SeasonSkipPreference` to show `PlayerSkipBannerView` or auto-skip once per item.
- **Episode Switching & Exit**:
  - `switchToEpisode(_:)`: Performs a `0ms` synchronous `@MainActor` cut whenever `prefetchedNextEpisodeResource`, offline entry, or `PlaybackIntentCoordinator.shared.cachedResolvedResource` hits; otherwise resolves asynchronously, reports `stopped` in background, resets per-item flags, notifies `companionBox.companion?.onLocalEpisodeSwitched(...)`, and optionally cleans up finished auto-archived cache entries.
  - `exitPlayer()` cancels `autoHideBox.autoHideTask`, removes `mouseMonitor`/`keyMonitor`, reports final stopped progress, syncs `DetailView` focused episode, notifies `companionBox.companion?.onPlayerClose()`, calls `stopNativeKernel()`, and clears `appState.activePlayback`.
- **Companion & GPU Danmu Gate**:
  - `configureAndBindCompanionIfNeeded()` binds `DonbyPlayerCompanion` (`UHDPlayerCompanionController` when UHD is active) via `DonbyPlayerHostDriver`.
  - Danmu loading is strictly gated until after `hasRenderedFirstFrame == true` (`PlayerView.swift` `.task(id:)`), rendered via reference-type `UHDDanmuTrack` into `DanmuSpriteHostView` (36 `CATextLayer` GPU pool, 5Hz spawn).

## 3. Concurrency Invariants
- Keep `nonisolated static` on `makeRedirectStoreHandler` and `makeRedirectInvalidateHandler` (invoked from background URLSession callbacks).
- Keep `dk_player_request_abort` safe via `OpeningPlayerBox` (`NSLock`) when cancelling mid-open.
