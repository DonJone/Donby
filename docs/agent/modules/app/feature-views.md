# App Sub-Map: Server, Files, Settings, Downloads & Utility Views

> Parent: [app/INDEX.md](INDEX.md). Covers 12 files (`ServerViews.swift`, `ServerConfigSheet.swift`, and 10 files under `Sources/DonbyApp/Views/`).

## 1. File Inventory & Responsibilities
- **Servers & Line Switching**:
  - `Sources/DonbyApp/ServerViews.swift` (`656L`) — `ServerListView`, `AddServerDashedCard`, `ServerCardView`, `ServerContextMenuItems`, `ServerLinePickSheet`, and `ServerLineOptionRow` (MUST stay `internal`; reused by `Modules/UHD/UHDAppExtensionPlugin.swift`).
  - `Sources/DonbyApp/ServerConfigSheet.swift` (`789L`) — Add/edit server Liquid Glass modal (`UHDAuthMode`, UHD/standard auth forms, clipboard parsing, connection test, save/connect via `DonbyAppExtensionCenter` / `DonbyMediaServiceRegistry`).
- **Files & Local Folders**:
  - `Views/FilesModuleView.swift` (`532L`) — Main files container, `@State` & filters, `body` + `.task` loaders, `filesMainTopBar`, `filesSearchAndFilterBar`, `filesOverviewContent`, file-panel & drag-drop handlers, `formatBadgeFor`.
  - `Views/FilesModuleView+FolderBrowser.swift` (`344L`) — Recursive folder drill-down UI (`folderDetailHeader`, `folderDetailContent`, `subfolderNavigationCard`, `folderVideoCard`, `formatByteCount`) + `private LocalFileThumbView`.
  - `Views/FilesModuleView+CardsAndSheets.swift` (`417L`) — Overview cards (`emptyFolderPlaceholderCard`, `localFolderCard`, `openAddFolderDialog`, `dropZoneCard`, `dropOverlay`, `fileMediaCard`, `emptyFilesPlaceholder`) and `directURLSheetContent`.
- **Settings & Software Updates**:
  - `Views/SettingsView.swift` (`669L`) — `SettingsSectionTab`, sidebar + `generalSettingsTab` (hosts `DonbyExtensionSettingsCard()`), `playerSettingsTab`, `networkSettingsTab`, `settingsCard`, `settingsHeader`, `SettingsTabRowButton`.
  - `Views/SettingsView+About.swift` (`390L`) — `aboutSettingsTab`, `shortcutRow`, `softwareUpdateCard`, `updateStateBanner`, `updateDateFormatter` (`AppUpdateManager.shared`).
- **Downloads & Offline Library**:
  - `Views/DownloadsView.swift` (`679L`) — Poster-wall vs queue mode switching, header bar, live transfer strip, queue/cache management, async disk usage scan (`refreshDiskUsage`).
  - `Views/DownloadRowCards.swift` (`306L`) — Pure-input `DownloadEntryRowCard` and `CachedAssetRowCard`.
- **Search, IPTV & Watch Records**:
  - `Views/GlobalSearchView.swift` (`527L`) — Cross-server global search & search history UI.
  - `Views/IPTVModuleView.swift` (`454L`) — M3U / IPTV channel list & live playback launcher.
  - `Views/RecordsView.swift` (`288L`) — Watch history records grid with resume/replay actions.

## 2. Critical Invariants (DO NOT BREAK)
1. **Settings Card Width & Traffic-Light Clearance (`v1.4.32`)**: Always wrap cards in `SettingsView` with `settingsCard(...)` enforcing `.frame(maxWidth: .infinity)`. Never place collapsed-sidebar buttons inside macOS's top-left `0...74pt` traffic-light zone (right-align `[sidebar.left]` inside the 190px settings sidebar header row).
2. **Async Disk I/O**: Keep `AppState.countFolderVideos`, `AppState.scanFolderHierarchy`, `DonbyOfflineLibraryStorage.scanOfflineLibrary`, and `NSImage(contentsOf:)` strictly inside `.task` / `Task.detached` (never in SwiftUI `body`).
3. **Professional CDN Naming & Zero AI-Slop Copy (`v1.4.34–v1.4.37`)**: Use full CDN labels (`Cloudflare Pro CDN`, `Cloudflare CDN`, `中国大陆 CDN`), omit fake CDN latency (`ms`) and exit geography from route rows, and preserve `ServerLineOptionRow` `internal` visibility.
4. **Keep `public init() {}`**: On `FilesModuleView` and `SettingsView`, keep explicit `public init() {}` intact so `internal` `@State` properties shared with extension files never synthesize memberwise initializers.
