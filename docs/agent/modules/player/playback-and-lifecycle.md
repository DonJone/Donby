# Player Sub-Map: Playback Engine, Timers & Session Lifecycle

> Parent: [player/INDEX.md](INDEX.md). Covers `PlayerView+PlaybackEngine.swift` and `PlayerView+LifecycleAndSession.swift`.

## 1. Native Kernel & Turbo Bridge (`PlayerView+PlaybackEngine.swift`)
- `PlayerView+PlaybackEngine.swift` — C-ABI callbacks, kernel open/stop/seek, 0.25s progress loop, health recovery.
- `PlayerView+LifecycleAndSession.swift` — 10s Emby sync, next-episode prefetch, intro/outro skip, episode switch/exit, companion & GPU danmu gate (Section 2).
- **C-ABI Callbacks (file-private top-level funcs)**: `dkTurboReadCB`, `dkTurboSeekCB`, `dkTurboAbortCB`, `dkTurboCloseCB` bridge `TurboStreamByteHandle` via `Unmanaged` into `dk_player_open_with_tracks`. Keep them file-private top-level functions (C function pointers cannot capture Swift context).
- **Startup & Open Flow**:
  - `startNativeKernelPlayback(startSeconds:)` increments `activePlaybackGeneration`, aborts any prior `OpeningPlayerBox`, computes `computePreOpenTrackHints()`, installs `makeRedirectStoreHandler`, attaches `TurboStreamByteHandle` when Turbo is active, opens the Rust kernel on `Task.detached`, applies initial `DKSubtitleStyleConfig`, and queries `queryKernelTracks` + `queryKernelChapters`.
  - Every `Task.detached` -> `MainActor.run` callback MUST check `self.activePlaybackGeneration == thisGeneration` to drop stale callbacks after rapid seek/retry/episode switch.
- **0.25s Progress Loop (`handleProgressTimerTick()`)**:
  - **Seek Settling Guard (`isSettlingSeek`)**: `2.5s` window after seek commit (`lastSeekCommitUptime` / `lastSeekCommitTarget`) so the scrubber does not snap back to stale pre-seek PTS while the decoder flushes.
  - **Stall / Health Policy**: Evaluates `PlaybackHealthPolicy` (`recover` triggers reconnect at `livePos`; `fail` surfaces `openingErrorMessage`).
  - **Side Effects**: Calls `evaluateIntroOutroSkipWindow()`, `prefetchNextEpisodeIfNearEnd()`, companion `onProgressTick(...)`, and periodic 5s local watch-progress saves (`lastRecordedPosition`).

## 2. Session, Episode Switching & Companion (`PlayerView+LifecycleAndSession.swift`)
- `PlayerView+LifecycleAndSession.swift` — 10s Emby sync, next-episode prefetch, intro/outro skip, episode switch/exit, companion & GPU danmu gate:
- **Remote Progress Sync (`handleEmbySyncTimerTick()`)**: 10s timer routing progress via `DonbyMediaServiceRegistry.shared.provider(for:)` or `EmbyClient.shared.reportPlaybackProgress(...)`.
- **Next-Episode Prefetch & Skip**:
  - `prefetchNextEpisodeIfNearEnd()`: Triggers at `>= max(duration * 0.72, duration - 120)` when next episode is not already downloaded/prefetched; caches `ResolvedPlaybackResource` in `prefetchedNextEpisodeResource`.
  - `evaluateIntroOutroSkipWindow()`: Combines `ChapterSkipDetector` (`kernelChapters`) with per-season `SeasonSkipPreference` to show `PlayerSkipBannerView` or auto-skip once per item.
- **Episode Switching & Exit**:
  - `switchToEpisode(_:)` cancels prior `episodeSwitchTask`, saves final progress, resolves/consumes prefetched resource, resets per-item flags, notifies `companionBox.companion?.onLocalEpisodeSwitched(...)`, and optionally cleans up finished auto-archived cache entries.
  - `exitPlayer()` cancels `autoHideBox.autoHideTask`, removes `mouseMonitor`/`keyMonitor`, reports final stopped progress, syncs `DetailView` focused episode, notifies `companionBox.companion?.onPlayerClose()`, calls `stopNativeKernel()`, and clears `appState.activePlayback`.
- **Companion & GPU Danmu Gate**:
  - `configureAndBindCompanionIfNeeded()` binds `DonbyPlayerCompanion` (`UHDPlayerCompanionController` when UHD is active) via `DonbyPlayerHostDriver`.
  - Danmu loading is strictly gated until after `hasRenderedFirstFrame == true` (`PlayerView.swift` `.task(id:)`), rendered via reference-type `UHDDanmuTrack` into `DanmuSpriteHostView` (36 `CATextLayer` GPU pool, 5Hz spawn).

## 3. Concurrency Invariants
- Keep `nonisolated static` on `makeRedirectStoreHandler` (invoked from `Task.detached`).
- Keep `dk_player_request_abort` safe via `OpeningPlayerBox` (`NSLock`) when cancelling mid-open.
