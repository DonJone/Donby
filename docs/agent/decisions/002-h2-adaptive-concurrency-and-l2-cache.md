# ADR-002: HTTP/2 Adaptive Concurrency, EWMA TTFB Rescue & Async L2 Disk Persistence

- **Status**: Accepted (Implemented in `v1.4.0`, commit `f35082e`)
- **Date**: 2026-11-21
- **Context**: Real-server UHD 4K Remux testing (14-55 GiB files over HTTP/2 Emby-compatible CDNs with ~1-2s TTFB and per-HTTP-stream bandwidth shaping during busy hours) exposed three failure modes:
  1. Synchronous `FileHandle.write()` + `.atomic` spill writes + `meta.json` writes inside `TieredAssetChunkStore.storeChunk()` stalled URLSession network callbacks.
  2. Launching 4+ concurrent HTTP/2 streams immediately on every seek during rapid scrubbing caused `RST_STREAM` churn and head-of-line contention.
  3. Conversely, overly restrictive concurrency or fixed short rescue timeouts caused buffer starvation on per-stream-throttled edges.

## Rejected Approaches (DO NOT RE-INTRODUCE)
1. **Locking `h2` concurrency to `2` when `leadCachedChunks < 2` (`effectiveCap = (leadCachedChunks < 2) ? 2 : 3`)**:
   - **Why it failed (Round 3 benchmark)**: When a CDN edge shapes each HTTP/2 stream to `~0.6-0.75 MB/s`, locking concurrency to 2 yields `< 1.5 MB/s` total throughput — below 4K Remux bitrate — causing a permanent recovery deadlock where `leadCachedChunks` never reaches 2.
   - **Measured scaling on shaped `h2` edge**: `N=1: 0.74 MB/s`, `N=2: 3.67 MB/s`, `N=3: 5.17 MB/s`, `N=4: 6.11 MB/s`, `N=6: 7.16 MB/s`.
2. **Fixed `1.5s` cold-response rescue timeout**:
   - **Why it failed**: On `1.3s-2.0s` TTFB CDNs, a fixed `1.5s` timeout fires right before the primary response headers arrive, triggering duplicate request storms that double server load and trigger throttling.

## Accepted Design
1. **Protocol Detection**: `TurboStreamingSessionHub` reads `URLSessionTaskMetrics` (`networkProtocolName`) and caches `hostProtocolMultiplexed` per host (`h2`/`h3` vs `http/1.1`).
2. **0.55s Seek-Burst Gate**: For the first `0.55s` after a seek (`timeSinceSeek < 0.55`), cap concurrency to `min(2, cap)` to halve `RST_STREAM` churn during rapid scrubbing. After `0.55s`, immediately open to full `cap`.
3. **Steady-State `h2` Cap**: Base cap `4` on `h2`/`h3`, dynamically scaling to `5` when measured throughput `< 4.5 MB/s` and `leadCachedChunks < 6`. Bounded Range spans (`2 MiB -> 2 MiB -> 4 MiB -> 6 MiB`).
4. **EWMA TTFB-Adaptive Cold Rescue**: Track `smoothedResponseTTFB`; set cold rescue threshold to `max(2.2, min(4.5, smoothedResponseTTFB * 2.5))`.
5. **Async L2 Disk Persistence**: `TieredAssetChunkStore` writes `media.bin` / `chunks/<idx>.chk` + `meta.json` on a dedicated serial `diskQueue` (`com.donby.chunkstore.disk`, `.utility`) with `pendingDiskChunks` read-through and 64-chunk backpressure cap.
   - **Critical Invariant**: Whenever `chunks/` is removed (e.g., `foldConsecutiveSpillChunksIntoMediaBinLocked` or `prepareContiguousMediaBinForMaterialization`), MUST reset `didEnsureChunksDir = false`.

## Verified Outcome (`v1.4.0`)
- Rapid Scrub Storm: `firstFrame=448ms`, `0` rebufs, `maxGap=52ms` (down from `1116ms` freeze + 1 rebuf).
- 55.32 GiB 4K Remux 20s sustained playback: `452 frames`, `p50=41.0ms`, `p95=49.5ms`, `max=62ms`, `0` freezes, `0` rebufs.
- L2 Disk Persistence Integrity: `hasChunk0=yes`, `hasEOF=yes`.
