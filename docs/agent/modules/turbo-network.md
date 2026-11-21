# Module Map: Turbo Cache, Streaming & Network (`DonbyNetwork`)

> Last synced: `v1.4.3`. Load this doc for streaming, seek latency, HTTP/2 Range, L1/L2 caching, detail-page preloading, Emby/UHD API, offline downloads, and channel-aware auto-updates.

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
- `Sources/DonbyNetwork/UHDStreamClient.swift` (~1682L)
  - UHD native API client: auth, subscriptions/limits, parallel domain resolution (`/playback/domains/*/resolve`), asset cache (TTL `300s`), `/play/*`, `/download/*`, speed-test.
- `Sources/DonbyNetwork/OfflineMediaLibrary.swift` (~576L)
  - `DonbyOfflineLibraryStorage`, `OfflineSeriesSidecar`, `OfflineEpisodeOrMovieSidecar`, pinned chunk-to-offline linkage.
- `Sources/DonbyNetwork/AppUpdateManager.swift` (~750L)
  - Channel-aware (`AppUpdateChannel`: `.stable` vs `.prerelease`) GitHub Releases / `latest.json` checker, `.app.zip` download, `ditto` hot-replace preserving `/Applications/Donby.app` inode.

## 2. Streaming & Caching Architecture (`TurboCacheAndDownloadEngine`)
- **Chunk Geometry**: `512 KiB` aligned chunks (`chunkSize`).
- **Two-Tier Storage (`TieredAssetChunkStore`)**:
  - **L1 Memory**: Fast dictionary cache with smart retention:
    - Pins **Chunk 0** (container header) and **final 2 EOF chunks** (MKV Cues / MP4 `moov`) so warm reopen `dk_open` drops from `485-841ms` to `~12ms`.
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
  - **Bounded Spans**: Progressive Range sizes `2 MiB -> 2 MiB -> 4 MiB -> 6 MiB`.
  - **Zero-Waste Unaligned Seek Sprint (`initialByteSkip`)**: When seeking into a chunk with `offsetInChunk >= 64 KiB`, Stream #1 starts at the exact seek byte offset and stashes partial head in `directSlices` for immediate delivery.
  - **EWMA TTFB-Adaptive Cold Rescue**: `max(2.2, min(4.5, smoothedResponseTTFB * 2.5))`.
  - **Chunk 0 & EOF Preservation**: Direct tail prefetch (up to `1 MiB`, final 2 chunks for `> 4 GiB`) survives open-probe seeks and persists complete aligned tail chunks; `trimmedEarly` lets offset-0 streams finish Chunk 0 (`512 KiB`) even if playback jumps away during cold resume.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **`didEnsureChunksDir` Reset**: Whenever `foldConsecutiveSpillChunksIntoMediaBinLocked` or `prepareContiguousMediaBinForMaterialization` deletes an empty `chunks/` directory, MUST reset `didEnsureChunksDir = false` (otherwise all later spill chunk writes silently fail, losing EOF cues).
2. **No 2-Stream Lock on Shaped `h2`**: Never gate `h2` concurrency down to 2 based on `leadCachedChunks < 2` (causes starvation deadlock on per-stream-throttled edges).
3. **No Short Fixed Rescue Timeout**: Never hardcode `< 2.0s` cold rescue timeout; high-TTFB CDNs (`1.3-2.0s`) will trigger duplicate request storms.
4. **429 Backoff**: Respect `ServerDeliveryCapabilities` (`active_video_delivery_limit`); on HTTP `429`, back off and step down concurrency.
5. **Audio Track Switch Wake**: Calling `activeTurboHandle?.wakeWaitingReads()` is required on mid-playback track switches so blocked AVIO reads unblock promptly.
6. **URL Redaction**: Never log raw stream URLs with query tokens; redact host/query in diagnostic logs.
