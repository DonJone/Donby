# Module Map: Core Models, Policies & Storage (`DonbyCore`)

> Last synced: `v1.4.13`. Load this doc for shared data models, `DONBY_HOME` storage path isolation, unified `DonbyAppInfo.version`, Keychain credential vault, async file logger, subtitle encoding/transform policies, diagnostics redaction, playback health state machine, update manifest parsing, and `DonbyCoreTests`.

## 1. File Inventory & Core Symbols
- `Sources/DonbyCore/DonbyStoragePaths.swift` (~52L)
  - `DonbyStoragePaths`: Centralized path resolver supporting `DONBY_HOME` environment override (`isIsolatedHome`, `cachesDirectoryURL`, `applicationSupportDirectoryURL`, `libraryDirectoryURL`, `moviesDirectoryURL`).
- `Sources/DonbyCore/ServerCredentialStore.swift` (~240L)
  - `ServerCredentialStore`, `ServerCredentialSecret`, `KeychainVaultBackend`, `IsolatedFileVaultBackend` — stores all server `password` and `accessToken` values in a **single** strictly scoped macOS Login Keychain entry (`service = com.don.Donby.credentials`, `account = server-credentials.v1`) using atomic `SecItemUpdate` -> `SecItemAdd`, automatic one-time migration from legacy plaintext `UserDefaults`, no-op write skipping when only metadata changes, and data-loss guards when Keychain access is denied/locked. Automatically routes to an isolated `0600` file when `DonbyStoragePaths.isIsolatedHome` is true so tests never touch the host Keychain.
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
- `Tests/DonbyCoreTests/DonbyCoreTests.swift`
  - Fast `swift test` regression suite covering encoding detection, ASS tag preservation, style v1->v2 migration, secret redaction, version comparison, and bounded health recovery.

## 2. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **`DONBY_HOME` Isolation**: Every cache/storage path in `DonbyNetwork` and `DonbyApp` MUST route through `DonbyStoragePaths` (never hardcode `FileManager.default.urls(for: .cachesDirectory, ...)` directly), so automated tests with `DONBY_HOME=$(mktemp -d)` remain 100% isolated from user data.
2. **ASS Tag Preservation**: Any changes to `SubtitleTextTransform` must preserve `{...}` ASS formatting tags intact.
3. **Diagnostic Redaction**: Never weaken `PlaybackDiagnosticsRedactor` secret-stripping regexes, and always redact stream URLs/tokens before calling `DonbyLogger.shared.log(...)`.
4. **Keychain Atomic Update & Isolation**: Never use `SecItemDelete` before `SecItemAdd` or omit `kSecAttrService` on Keychain queries; never overwrite the Keychain vault if startup read failed (`vaultReadBlocked == true`); always isolate via `IsolatedFileVaultBackend` when `DonbyStoragePaths.isIsolatedHome == true`.
