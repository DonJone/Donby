# Module Map: Optional UHDNow Streaming Integration (`DonbyUHDModule` & `Modules/UHD`)

> Last synced: `v2.0.2`. Load this doc for UHDNow REST/WebSocket protocol behavior, dual-mode artwork resolution, single-episode detail hydration, CDN line selection/speed test, Watch Party, and GPU Danmu.

## 1. File Inventory (Target Split: `<= 800L` per file)
- **`Sources/DonbyUHDModule/`** (Optional SwiftPM target; excluded cleanly when `DONBY_PURE=1`):
  - `UHDModuleConfig.swift` (`282L`) — `UHDModuleEndpoints` (`smart.uhdnow.com` -> `v1.uhdnow.com` fallback, China-optimized default line selection), `DonbyUHDServiceProvider` (`DonbyMediaServiceRegistry`), `DonbyUHDModule.install()` / `uninstall()`.
  - `UHDAPIModels.swift` (`791L`) & `UHDDomainNormalizers.swift` (`417L`) — domain DTOs, `UHDSpeedTestMetricsEngine`, `UHDLoginCodeNormalizer`, `UHDWatchPartyInviteParser`, `UHDTmdbSearchQueryParser`, `UHDRatingNormalizer`, `UHDDisplayNormalizer`.
  - `UHDStreamClient.swift` (`278L`) — Actor core, `DonbyNetworkSession.sharedURLSession` sharing, `APIRequestGate` integration, raw `Authorization: <token>` header construction (no `Bearer` prefix), `UHDResolvedDomainCache`, `UHDAssetResponseCache`.
  - `UHDStreamClient+AuthAndAccount.swift` (`408L`) — password/code/token auto-fallback login, subscription/traffic snapshots.
  - `UHDStreamClient+SpeedTestAndLines.swift` (`534L`) — `/playback/domains` listing, `/resolve` edge base resolution, `TEST_BASE` chunk speed test, exit IP probe.
  - `UHDStreamClient+CatalogAndSearch.swift` (`550L`) — collections, `playback-states` (`resume` + `nextUp`), hot/anime/calendar, genres, persons, TMDB search, favorites.
  - `UHDStreamClient+DetailAndMapping.swift` (`900L` range) — `fetchItemDetail` (with ambiguous-stub 404 retry across `episode`/`movie`/`tv`), `fetchSeasons`, paginated `fetchSeasonEpisodes` (`page_size=100`, auto-fetches pages `2...20` when `total > 100`), `fetchCredits`, `fetchAssetMediaSources`, `resolvePlaybackResource`, DTO mappers (`mapSummary`, `mapDetail`, `mapEpisode` with season poster / series fanart / series logo fallbacks).
  - `UHDStreamClient+TeamAdmin.swift` (`163L`), `UHDWatchPartyClient.swift` (`~450L`), `UHDDanmuClient.swift` (`~331L`).
- **`Sources/DonbyApp/Modules/UHD/`** (UI plugin slots registered via `DonbyAppExtensionCenter`):
  - `UHDModuleManager.swift` (`698L`) — toggle state, home loading (`resumeItems` + `nextUpItems` + `hotItems`), `resolveSeriesStartEpisode`, Watch Party creation.
  - `UHDAppExtensionPlugin.swift` (`662L` range) — `DonbyAppUIExtensionPlugin` impl; `loadDetailPayload` resolves stub episode `seriesId` first when missing so credits/seasons/playback-state load reliably.
  - `UHDPlayerCompanionController.swift` (`538L`), `UHDAccountDashboardView.swift`, `UHDSpeedTestPanelView.swift`, `UHDDiscoverySheets.swift`, `UHDWatchPartyAndDanmuViews.swift`.

## 2. Network & Artwork Architecture Contracts
1. **Shared Media Data Plane**: Video streaming (`ResolvedPlaybackResource`), Range scheduling, L1/L2 chunk caching, detail preloading, and offline downloads run on the exact same `DonbyTurboCacheEngine` / `TurboStreamByteHandle` / `KernelRust` pipeline as standard Emby.
2. **Control Plane vs Edge Delivery**: JSON API calls hit `server.mainLineURL` with raw `Authorization: <token>`; video/subtitle `/play/*` and `/download/*` paths resolve against the edge base returned by `/api/v1/stream/playback/domains/{id}/resolve` (300s TTL in `UHDResolvedDomainCache`).
3. **Zero Auth & Zero Server Resize on `/img/...`**: Static `/img/...` URLs resolve against `server.mainLineURL` without auth headers or `?maxWidth=` query params (`EmbyClient.makeImageRequest` omits `X-Emby-*` headers when `isUHDNativeExtensionActive` is true).
4. **Dual-Mode Artwork Fallback (`EmbyClient+ArtworkAndFallback.swift` & `MediaArtworkViews.swift`)**:
   - `EmbyClient.imageURL(server:itemId:)` returns `nil` when `isUHDNativeExtensionActive(for: server)` is true so UHD tokens never leak into `/emby/Items/...?api_key=` 401/404 storms.
   - `imageURL(server:item:)` and `MediaArtworkView.candidateURLs` resolve direct URLs with fallback: `.primary` checks `[uhdPosterURL, uhdThumbURL, uhdBackdropURL]`; `.backdrop` checks `[uhdBackdropURL, uhdThumbURL, uhdPosterURL]`; `.thumb` checks `[uhdThumbURL, uhdBackdropURL, uhdPosterURL]`; `.logo` checks `[uhdLogoURL]`.
   - Season episode fetches inherit `season.poster_url ?? series.poster_url`, `series.fanart_url`, and `series.logo_url` via `EmbyItem.withInheritedArtworkFallback(...)` for episodes missing `thumb_url`.
5. **Extension Firewall**: Keep `#if canImport(DonbyUHDModule)` strictly confined to `DonbyAppExtensionCenter` and `Modules/UHD/`. When `DonbyUHDModule` is disabled or compiled out (`DONBY_PURE=1`), `EmbyClient` falls back to normalized `e`/`s`/`m` + ULID Emby routes.
