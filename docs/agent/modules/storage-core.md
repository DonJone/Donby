# Module Map: Core Models, Policies & Storage (`DonbyCore` & `DonbyStorage`)

> Last synced: `v1.4.0` (`f35082e`). Load this doc for shared data models, `DONBY_HOME` storage path isolation, subtitle encoding/transform policies, playback health state machine, update manifest parsing, logging, and Keychain.

## 1. File Inventory & Core Symbols
- `Sources/DonbyCore/DonbyStoragePaths.swift` (~48L)
  - `DonbyStoragePaths`: Centralized path resolver supporting `DONBY_HOME` environment override (`cachesDirectoryURL`, `applicationSupportDirectoryURL`, `libraryDirectoryURL`, `moviesDirectoryURL`).
- `Sources/DonbyCore/DonbyLogger.swift` (~172L)
  - `DonbyLogger`, `DonbyLogLevel`, `DonbyLogEntry` — in-memory ring + file logging with diagnostic export & regex secret redaction (`token|password|passwd|pwd|authorization|api_key`).
- `Sources/DonbyCore/SubtitleAndPlaybackPolicies.swift` (~816L)
  - `SubtitleTextDecoder` — BOM check + ordered fallback (`UTF-8 -> Big5 (2563) -> GB18030 (1586) -> UTF-16LE -> UTF-16BE`) with Chinese punctuation plausibility scoring.
  - `SubtitleTextTransform` — `CFStringTransform` (`Hant-Hans` / `Hans-Hant`) preserving `{...}` ASS override tags.
  - `SubtitleHDRPeakNits` (`203 / 250 / 400`), `SubtitleStyleConfiguration`.
  - `SeasonSkipPreference` (`introEnabled`, `outroEnabled`, `introSeconds`, `outroSeconds`, `SeasonSkipMode`: `.manual` / `.automatic`, `chapterDetection`), `ChapterSkipDetector`.
  - `PlaybackHealthPolicy` & `PlaybackHealthEvaluation` — bounded stall detection (monitors time progress `>= 0.1s` or buffer progress `>= 0.5s`; triggers `.recover` once before `.fail`).
- `Sources/DonbyCore/EmbyModels.swift` (~836L) & `EmbyChapterInfo.swift` (~18L) & `ResolvedPlaybackResource.swift` (~40L)
  - `ServerType` (`.emby`, `.jellyfin`, `.uhdNative`, etc.), `EmbyServerConfig`, `ServerLineInfo`, `EmbyExtServerDomainsResponse`, `ResolvedPlaybackResource`, `SubtitleResourceItem`.
- `Sources/DonbyCore/AppStateModels.swift` (~485L)
  - `MainNavigationTab`, `ActivePlaybackSession`, `WatchRecordItem`, `LocalMediaFolder`, `IPTVChannelItem`, `AppThemeColor`, `AppAppearanceMode`.
- `Sources/DonbyCore/AppUpdatePolicies.swift` (~270L)
  - `AppReleaseInfo`, `AppVersionComparator`, `GitHubReleaseDTO`, `StaticManifestDTO` (`latest.json`).
- `Sources/DonbyCore/ServerTextParser.swift` (~306L)
  - Bulk/paste server config importer (`ParsedServerImportResult`).
- `Sources/DonbyStorage/KeychainStorage.swift` (~60L)
  - macOS Keychain wrapper for server credentials/tokens.

## 2. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **`DONBY_HOME` Isolation**: Every cache/storage path in `DonbyNetwork` and `DonbyApp` MUST route through `DonbyStoragePaths` (never hardcode `FileManager.default.urls(for: .cachesDirectory, ...)` directly), so automated tests with `DONBY_HOME=$(mktemp -d)` remain 100% isolated from user data.
2. **ASS Tag Preservation**: Any changes to `SubtitleTextTransform` must preserve `{...}` ASS formatting tags intact.
3. **Diagnostic Redaction**: Never weaken `DonbyLogger` secret-stripping regexes.
