# Module Map: Turbo Cache, Streaming & Network (`DonbyNetwork`)

> Last synced: `v1.4.34`. Load this doc for streaming, seek latency, HTTP/2 Range, L1/L2 caching, detail-page preloading, Emby API, optional `DonbyUHDModule` (Smart->V1 routing, speed test, Watch Party, Danmu), offline downloads, and channel-aware auto-updates.

## 1. File Inventory & Core Symbols
- `Sources/DonbyNetwork/TurboCacheAndDownloadEngine.swift` (~4754L)
  - `APIRequestGate` (`Priority`: `.playback` vs `.normal`) — isolates playback API calls from artwork/browse traffic.
  - `ServerDeliveryCapabilities` — server-advertised `active_video_delivery_limit` & `allow_download`.
  - `ChunkStoreMeta` + `TieredAssetChunkStore` — L1 in-memory chunk pool + L2 disk persistence (`media.bin` + `chunks/<idx>.chk` + `meta.json`).
  - `TurboStreamingSessionHub` — shared `URLSession` hub, `URLSessionTaskMetrics` protocol detection (`hostProtocolMultiplexed` for `h2`/`h3` vs `http/1.1`), redirect caching.
  - `TurboStreamByteHandle` — custom `AVIOContext` byte-stream provider (`read(at:length:)`, `seek`, `wakeWaitingReads()`, `directSlices`, `ActiveAttemptRecord`).
  - `DonbyTurboCacheEngine` — asset lifecycle, download queue, cache eviction, offline materialization, auto-archive, and single-slot background detail-page preloader (`startDetailPreload` / `cancelDetailPreload`).
- `Sources/DonbyNetwork/EmbyClient.swift` (~1135L)
  - `RedirectCacheStore`, `EmbyPlaybackInfoCache` (TTL `300s`), `EmbyHostWarmCache`, `NoRedirectDelegate`, `EmbyClient`.
- `Sources/DonbyUHDModule/` (Standalone optional SwiftPM target; cleanly toggleable/uninstallable; zero reverse dependency from `DonbyCore`/`DonbyNetwork`):
  - `UHDModuleConfig.swift` (~265L) — `UHDModuleEndpoints` (zero-URL `smart.uhdnow.com` -> `v1.uhdnow.com` fallback & China-optimized primary line selection), `DonbyUHDServiceProvider` bridged into `DonbyMediaServiceRegistry`, `DonbyUHDModule.install()` / `uninstall()`.
  - `UHDModels.swift` (~1080L) — UHD domain models, `UHDSpeedTestMetricsEngine`, `UHDLoginCodeNormalizer`, `UHDWatchPartyInviteParser`, `UHDTmdbSearchQueryParser`, `UHDRatingNormalizer`.
  - `UHDStreamClient.swift` (~1720L) — UHD native API client (`streaming-openapi.yaml v1.0.0-draft.2` + `team-v2-openapi.yaml`): auto-fallback password/code/token login, full subscription/traffic account snapshots, domain listing & fresh `/resolve`, spec-compliant `TEST_BASE` chunk-delegate speed test (`32/64/100 MiB`, warmup exclusion, cancel-safe no-report, free `probeLineExitNetworkInfo`), hot/anime-hot/anime-calendar/genres/persons/person-works, cross-season `/tv/{id}/playback-state`, TMDB ID search, typed favorites (`movie`/`tv`/`person`), Team API v2 management, `/play/*`, `/download/*`.
  - `UHDWatchPartyClient.swift` (~450L) — Watch Party REST client + `@MainActor UHDWatchPartySession` WebSocket sync.
  - `UHDDanmuClient.swift` (~240L) — UHD managed Danmu proxy client (zero quota consumption).
- `Sources/DonbyNetwork/OfflineMediaLibrary.swift` (~576L)
  - `DonbyOfflineLibraryStorage`, `OfflineSeriesSidecar`, `OfflineEpisodeOrMovieSidecar`, pinned chunk-to-offline linkage.
- `Sources/DonbyNetwork/AppUpdateManager.swift` (~750L)
  - Channel-aware (`AppUpdateChannel`: `.stable` vs `.prerelease`) GitHub Releases / `latest.json` checker, `.app.zip` download, `ditto` hot-replace preserving `/Applications/Donby.app` inode.

## 2. Streaming & Caching Architecture (`TurboCacheAndDownloadEngine`)
- **Chunk Geometry**: `512 KiB` aligned chunks (`chunkSize`).
- **Two-Tier Storage (`TieredAssetChunkStore`)**:
  - **L1 Memory**: Fast dictionary cache with smart retention:
    - Pins **Chunks 0..3** (`2 MiB` head runway) and **final 2 EOF chunks** (MKV Cues / MP4 `moov`) so warm reopens start in `<20ms` without running dry on high-TTFB edges.
    - Skips behind-cursor eviction while `memoryBytes <= 75%` of `maxMemoryBytes` for instant `-5s/-10s` rewinds.
  - **L2 Disk (Async)**:
    - `storeChunk()` inserts into L1 + `pendingDiskChunks` and dispatches writes to serial `diskQueue` (`com.donby.chunkstore.disk`, `.utility`), avoiding `URLSession` callback stalls.
    - Backpressure cap: `64` pending chunks; no `.atomic` overhead on spill chunks.
    - Contiguous prefix written to `media.bin`; out-of-order chunks written to `chunks/<idx>.chk` and folded into `media.bin` sequentially (anti-sparse compaction).
    - `flushMeta()`, `closeFileHandles()`, `prepareContiguousMediaBinForMaterialization()`, and `removeAsset()` drain `diskQueue.sync {}`.
- **HTTP/2 Adaptive Multi-Stream Range Scheduling (`TurboStreamByteHandle`)**:
  - See [../decisions/002-h2-adaptive-concurrency-and-l2-cache.md](../decisions/002-h2-adaptive-concurrency-and-l2-cache.md) for full rationale.
  - **0.55s Seek-Burst Gate**: `min(2, cap)` streams for first `0.55s` post-seek to halve `RST_STREAM` churn during rapid scrubbing.
  - **Steady-State Cap**: `4` streams on `h2`/`h3` (scales to `5` when throughput `< 4.5 MB/s` and `leadCachedChunks < 6`).
  - **Bounded Spans**: Progressive Range sizes `2 MiB -> 2 MiB -> 4 MiB -> 6 MiB` (outer lookahead spans stay compact at `2 MiB` while immediate playhead runway `< 4` contiguous chunks).
  - **Zero-Waste Unaligned Seek Sprint (`initialByteSkip`)**: When seeking into a chunk with `offsetInChunk >= 64 KiB`, Stream #1 starts at the exact seek byte offset and stashes partial head in `directSlices` for immediate delivery.
  - **EWMA TTFB-Adaptive Cold Rescue & Slow-Crawl Rescue**: Cold TTFB rescue uses `max(2.2, min(4.5, smoothedResponseTTFB * 2.5))`; once headers arrive (`chunkStartTimestamp` reset on response headers), immediate playhead chunks (`idx <= currentChunk + 1`) crawling below `280 KB/s` for `> 1.8s` also trigger a `1 MiB` rescue stream.
  - **Chunk 0..3 & EOF Preservation**: Direct tail prefetch (up to `1 MiB`, final 2 chunks for `> 4 GiB`) survives open-probe seeks; `TurboStreamByteHandle.init` immediately launches urgent `Chunk 1` when `Chunk 0` is already warm; `startDetailPreload` fetches `Chunks 0..3` (`2 MiB`) in step 1 when starting at `0s` so interrupting preload never leaves a Chunk-0-only trap.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **`didEnsureChunksDir` Reset**: Whenever `foldConsecutiveSpillChunksIntoMediaBinLocked` or `prepareContiguousMediaBinForMaterialization` deletes an empty `chunks/` directory, MUST reset `didEnsureChunksDir = false` (otherwise all later spill chunk writes silently fail, losing EOF cues).
2. **No 2-Stream Lock on Shaped `h2`**: Never gate `h2` concurrency down to 2 based on `leadCachedChunks < 2` (causes starvation deadlock on per-stream-throttled edges).
3. **No Short Fixed Rescue Timeout**: Never hardcode `< 2.0s` cold rescue timeout; high-TTFB CDNs (`1.3-2.0s`) will trigger duplicate request storms.
4. **429 Backoff**: Respect `ServerDeliveryCapabilities` (`active_video_delivery_limit`); on HTTP `429`, back off and step down concurrency.
5. **Audio Track Switch Wake**: Calling `activeTurboHandle?.wakeWaitingReads()` is required on mid-playback track switches so blocked AVIO reads unblock promptly.
6. **URL Redaction**: Never log raw stream URLs with query tokens; redact host/query in diagnostic logs.
