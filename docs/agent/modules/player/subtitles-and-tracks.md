# Player Sub-Map: Track Selection, Subtitles & AI Auto-Alignment

> Parent: [player/INDEX.md](INDEX.md). Covers `PlayerView+TrackSelection.swift` (`344L`) and `PlayerView+SubtitlesAndAlignment.swift` (`442L`).

## 1. Deterministic Track Mapping (`PlayerView+TrackSelection.swift`)
- **AVStream <-> Emby Resolution**: `embyAudioStreams`, `embySubtitleStreams`, `resolvedAudioOptions`, and `resolvedSubtitleOptions` reconcile `kernelAudioTracks`/`kernelSubtitleTracks` (discovered via `queryKernelTracks(handle:)`) with Emby/UHD `MediaSource` metadata so labels, languages, and indices stay consistent across embedded and remote-external tracks.
- **Audio & Subtitle Switching**:
  - `selectAudioOption(_:)` switches the kernel audio stream and calls `activeTurboHandle?.wakeWaitingReads()` so buffered Turbo reads resume without stalling.
  - `applySubtitleOptionOnStartup(_:)`, `selectSubtitleOption(_:)`, and `disableSubtitles()` manage primary subtitle state (`activeSubtitleSelection`, `explicitSubtitleOff`, per-scope memory via `appState.recordSubtitleChoice`).
  - `selectSecondarySubtitleOption(_:)`, `disableSecondarySubtitle()`, and `secondarySubtitleStatusTitle(options:)` manage dual-subtitle secondary track selection (`activeSecondarySubtitleSelection`).

## 2. External Subtitles, Style Config & AI Alignment (`PlayerView+SubtitlesAndAlignment.swift`)
- **External Subtitle Loading**:
  - `loadRemoteExternalSubtitle(...)`: Downloads via `EmbyClient` / UHD direct URL, decodes BOM/GB18030 via `DonbyCore` subtitle decoder, and loads into kernel primary or secondary slot.
  - `promptLocalExternalSubtitleFile(...)` / `loadLocalExternalSubtitleURL(...)`: `NSOpenPanel` picker for local `.srt`/`.ass`/`.ssa`/`.vtt` files.
- **Kernel Style Bridge**:
  - `resolvedDualAnchorMode()` resolves dual-subtitle anchor mode based on active primary/secondary state and `SubtitleStyleConfiguration`.
  - `nonisolated static func makeKernelSubtitleStyleConfig(_:anchorMode:)` builds `DKSubtitleStyleConfig` (font, size, vertical position, dual layout, border width, HDR peak nits, ASS override, forced-only, anti-occlusion). MUST remain `nonisolated static` because `startNativeKernelPlayback` calls it from `Task.detached`.
  - `applyKernelSubtitleStyle()` pushes live updates to `dk_player_set_subtitle_style`.
- **AI Auto-Alignment & Undo**:
  - `snapshotSubtitleIntervals(...)`: Captures active primary/secondary subtitle cue intervals from kernel for alignment.
  - `runAutoAlignAudioToSubtitle()`: Runs Silero VAD + `SubtitleAutoAligner` against decoded audio; shifts primary (and anchored secondary) delay while saving `SubtitleAlignUndoState`.
  - `runAutoAlignDualSubtitles()`: Aligns secondary subtitle offset + frame-rate drift (`secondarySubtitleTimeScale`) to primary subtitle.
  - `undoLastSubtitleAlignment()` & `resetSecondarySubtitleTimeScale()`: Restores exact prior delays/scale from `lastSubtitleAlignUndo`.
