# Player Sub-Map: Track Selection, Subtitles & AI Auto-Alignment

> Last synced: `v2.1.5`
> Parent: [player/INDEX.md](INDEX.md). Covers `PlayerView+TrackSelection.swift` and `PlayerView+SubtitlesAndAlignment.swift`.

## 1. Deterministic Track Mapping (`PlayerView+TrackSelection.swift`)
- `PlayerView+TrackSelection.swift` — AVStream <-> Emby track reconciliation, primary/secondary audio & subtitle switching (cancels any in-flight `SubtitleAlignmentCoordinator` task on track change).
- `PlayerView+SubtitlesAndAlignment.swift` — Remote/local external subtitles, `DKSubtitleStyleConfig`, `SubtitleAlignmentMode`/`SubtitleAlignmentCoordinator`, Silero VAD & dual-subtitle auto-alignment/undo (Section 2).
- **AVStream <-> Emby Resolution**: `embyAudioStreams`, `embySubtitleStreams`, `resolvedAudioOptions`, and `resolvedSubtitleOptions` reconcile `kernelAudioTracks`/`kernelSubtitleTracks` (discovered via `queryKernelTracks(handle:)`) with Emby/UHD `MediaSource` metadata so labels, languages, and indices stay consistent across embedded and remote-external tracks.
- **Audio & Subtitle Switching**:
  - `selectAudioOption(_:)` switches the kernel audio stream and calls `activeTurboHandle?.wakeWaitingReads()` so buffered Turbo reads resume without stalling.
  - `applySubtitleOptionOnStartup(_:)`, `selectSubtitleOption(_:)`, and `disableSubtitles()` manage primary subtitle state (`activeSubtitleSelection`, `explicitSubtitleOff`, per-scope memory via `appState.recordSubtitleChoice`).
  - `selectSecondarySubtitleOption(_:)`, `disableSecondarySubtitle()`, and `secondarySubtitleStatusTitle(options:)` manage dual-subtitle secondary track selection (`activeSecondarySubtitleSelection`).

## 2. External Subtitles, Style Config & AI Alignment (`PlayerView+SubtitlesAndAlignment.swift`)
- **External Subtitle Loading**:
  - `loadRemoteExternalSubtitle(...)`: Downloads via `EmbyClient` / UHD direct URL, decodes BOM/GB18030 via `DonbyCore` subtitle decoder, and verifies both `activePlaybackGeneration` and `activeSubtitleSelection` / `activeSecondarySubtitleSelection` on both completion and error branches before mutating state or loading into kernel.
  - `promptLocalExternalSubtitleFile(...)` / `loadLocalExternalSubtitleURL(...)`: Sheet-modal `NSOpenPanel.beginSheetModal` picker (non-blocking) for `.srt`/`.ass`/`.ssa`/`.vtt` files with async background `Data` read/decode and generation/selection race checks.
- **Kernel Style Bridge**:
  - `resolvedDualAnchorMode()` resolves dual-subtitle anchor mode based on active primary/secondary state and `SubtitleStyleConfiguration`.
  - `nonisolated static func makeKernelSubtitleStyleConfig(_:anchorMode:)` builds `DKSubtitleStyleConfig` (font, size, vertical position, dual layout, border width, HDR peak nits, ASS override, forced-only, anti-occlusion). MUST remain `nonisolated static` because `startNativeKernelPlayback` calls it from `Task.detached`.
  - `applyKernelSubtitleStyle()` pushes live updates to `dk_player_set_subtitle_style` and posts `Notification.Name("DonbyMetalRequestPausedSubtitleRedraw")` with `["handle": UInt(bitPattern: handle)]` (avoiding `subtitleStyleRevision` `@State` full `PlayerView` re-renders).
- **AI Auto-Alignment & Undo**:
  - `SubtitleAlignmentMode` (`.none`, `.audioToSubtitle`, `.dualSubtitles`) & `SubtitleAlignmentCoordinator` manage cancellable `alignmentTask` execution, mode-specific drawer spinners, and user cancellation (`cancelActiveSubtitleAlignment(showToast:)`).
  - `snapshotSubtitleIntervals(...)`: Captures active primary/secondary subtitle cue intervals from kernel for alignment.
  - `runAutoAlignAudioToSubtitle()`: Runs Silero VAD + `SubtitleAutoAligner` against decoded audio; verifies `Task.isCancelled`, generation, and unchanged primary/secondary selection before shifting delays and saving `SubtitleAlignUndoState`.
  - `runAutoAlignDualSubtitles()`: Aligns secondary subtitle offset + frame-rate drift (`secondarySubtitleTimeScale`) to primary subtitle with identical cancellation/selection race guards.
  - `undoLastSubtitleAlignment()` & `resetSecondarySubtitleTimeScale()`: Restores exact prior delays/scale from `lastSubtitleAlignUndo`.
