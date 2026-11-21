# Module Map: Core Models, Policies & Storage (`DonbyCore`)

> Last synced: `v1.4.18`. Load this doc for shared data models, `DONBY_HOME` storage path isolation, unified `DonbyAppInfo.version`, AES-256-GCM local credential vault, async file logger, subtitle encoding/transform/auto-alignment policies (Silero VAD + audio-first dual-subtitle aligner), diagnostics redaction, playback health state machine, update manifest parsing, and `DonbyCoreTests`.

## 1. File Inventory & Core Symbols
- `Sources/DonbyCore/DonbyStoragePaths.swift` (~52L)
  - `DonbyStoragePaths`: Centralized path resolver supporting `DONBY_HOME` environment override (`isIsolatedHome`, `cachesDirectoryURL`, `applicationSupportDirectoryURL`, `libraryDirectoryURL`, `moviesDirectoryURL`).
- `Sources/DonbyCore/ServerCredentialStore.swift` (~248L)
  - `ServerCredentialStore`, `ServerCredentialSecret`, `EncryptedFileVaultBackend` — stores all server `password` and `accessToken` values in a machine-bound **AES-256-GCM** encrypted `0600` file (`Application Support/Donby/credentials.vault`, key derived via `CryptoKit` HKDF-SHA256 + `IOPlatformUUID`). Eliminates macOS Login Keychain per-update password prompts on ad-hoc signed builds, automatically honors `DONBY_HOME`, performs one-time migration out of legacy plaintext `UserDefaults` and `v1.4.13–v1.4.15` Keychain entries (deleting the old Keychain item afterward), skips writes on metadata-only updates, and preserves credentials on read/write failures.
- `Sources/DonbyCore/DonbyLogger.swift` (~177L)
  - `DonbyLogger`, `DonbyLogLevel`, `DonbyLogEntry` — in-memory ring + serial background `ioQueue` file logging (non-blocking log writes and lock-free file export). Note: `DonbyLogger` itself does NOT redact strings; callers logging URLs/tokens MUST pass them through `PlaybackDiagnosticsRedactor.redact(_:)`.
- `Sources/DonbyCore/SubtitleAndPlaybackPolicies.swift` (~951L)
  - `SubtitleTextDecoder` — BOM check + ordered fallback (`UTF-8 -> Big5 (2563) -> GB18030 (1586) -> UTF-16LE -> UTF-16BE`) with Chinese punctuation plausibility scoring.
  - `SubtitleTextTransform` — `CFStringTransform` (`Hant-Hans` / `Hans-Hant`) preserving `{...}` ASS override tags.
  - `SubtitleHDRPeakNits` (`203 / 250 / 400`), `SubtitleStyleConfiguration` (`schemaVersion = 2` one-time v1->v2 migration).
  - `SeasonSkipPreference` (`introEnabled`, `outroEnabled`, `introSeconds`, `outroSeconds`, `SeasonSkipMode`: `.manual` / `.automatic`, `chapterDetection`), `ChapterSkipDetector`.
  - `PlaybackHealthPolicy` & `PlaybackHealthEvaluation` — bounded stall detection (monitors time progress `>= 0.1s` or buffer progress `>= 0.5s`; triggers `.recover` once before `.fail`).
  - `PlaybackDiagnosticsRedactor` — regex secret & host redaction (`token|password|passwd|pwd|authorization|api_key|x-emby-token|delivery_key` + `https?://<HOST>`).
- `Sources/DonbyCore/EmbyModels.swift` (~814L) & `EmbyChapterInfo.swift` (~18L) & `ResolvedPlaybackResource.swift` (~40L)
  - `ServerType` (`.emby`, `.jellyfin`, `.uhdNative`, etc.), `EmbyServerConfig`, `ServerLineInfo`, `EmbyExtServerDomainsResponse`, `ResolvedPlaybackResource`, `SubtitleResourceItem`.
- `Sources/DonbyCore/AppStateModels.swift` (~485L)
  - `MainNavigationTab`, `ActivePlaybackSession`, `WatchRecordItem`, `LocalMediaFolder`, `IPTVChannelItem`, `AppThemeColor`, `AppAppearanceMode`.
- `Sources/DonbyCore/AppUpdatePolicies.swift` (~334L)
  - `DonbyAppInfo` (single Swift source of truth for `version` & `fallbackVersion`), `AppReleaseInfo`, `AppVersionComparator`, `GitHubReleaseDTO`, `StaticManifestDTO` (`latest.json`).
- `Sources/DonbyCore/ServerTextParser.swift` (~306L)
  - Bulk/paste server config importer (`ParsedServerImportResult`).
- `Sources/DonbyCore/SubtitleAutoAligner.swift` (~760L)
  - `SileroVAD` — zero-dependency native Apple `Accelerate` (`vDSP_mmul`) inference engine for official Silero VAD v5/v6 `16kHz` weights (`Resources/silero_vad_16k.safetensors`, 1.24 MB, MIT; verified `< 1e-4` against official `silero_vad.jit` golden outputs).
  - `SubtitleAutoAligner` — Audio-first ground-truth alignment: (1) `alignAudioFirst`: overlap-clipped exact Pearson VAD correlation (`>= 10s` audio, `>= 65%` valid cue overlap, split-half consistency check, current-delay/zero-lag stability guard) that locks both primary and secondary tracks to audio in one click; (2) `alignDualAudioAnchored` / `alignDualSubtitles`: 2-stage coarse-to-fine (`0.25s -> 0.04s`) multi-window envelope cross-correlation + cinema FPS drift (`23.976/24/25fps`) + Silero VAD anchor selection so an audio-synced secondary track pulls a drifted primary track instead of being dragged off-sync.
- `Tests/DonbyCoreTests/DonbyCoreTests.swift`
  - Fast `swift test` regression suite (13 tests) covering encoding detection, ASS tag preservation, style v1->v2 migration, secret redaction, version comparison, bounded health recovery, encrypted vault tamper rejection, Silero VAD golden parity, audio-to-subtitle shift recovery, dual-subtitle shift + FPS drift alignment, and audio-anchored dual/post-seek detour prevention.

## 2. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **`DONBY_HOME` Isolation**: Every cache/storage path in `DonbyNetwork` and `DonbyApp` MUST route through `DonbyStoragePaths` (never hardcode `FileManager.default.urls(for: .cachesDirectory, ...)` directly), so automated tests with `DONBY_HOME=$(mktemp -d)` remain 100% isolated from user data.
2. **ASS Tag Preservation**: Any changes to `SubtitleTextTransform` must preserve `{...}` ASS formatting tags intact.
3. **Diagnostic Redaction**: Never weaken `PlaybackDiagnosticsRedactor` secret-stripping regexes, and always redact stream URLs/tokens before calling `DonbyLogger.shared.log(...)`.
4. **Zero Keychain Prompts on Ad-Hoc Builds (`v1.4.16`)**: Never store routine server credentials in macOS Login Keychain while Donby uses ad-hoc signing (`codesign -s -`), as CDHash changes trigger macOS password dialogs on every update. Keep credentials in the machine-bound AES-256-GCM `0600` vault (`EncryptedFileVaultBackend`) and preserve `vaultReadBlocked` / write-failure data-loss guards.
