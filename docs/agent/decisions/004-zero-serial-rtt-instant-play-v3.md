# ADR-004: Zero-Serial-RTT Instant Play Architecture (Turbo Engine v3)

- **Status**: Accepted (Implemented in `v2.0.25`)
- **Date**: 2026-11-27
- **Context**: Real-world 4K HEVC/DoVi Remux telemetry on `v2.0.24` (64-65 track MKV files, per-stream busy-hour shaping `0.6-1.5 MB/s`, cross-node 302 redirects, `0.4-2.0s` TTFB) showed `160ms` startup ONLY when clicking the primary `DetailView` Play button after full detail preload completed. Direct episode-card clicks, episode switches, cold resume opens, and single-click seeks still suffered `1.41s-3.74s` end-to-end latency (up to `11.29s` worst-case cold resume) and occasional `rebuf=1` (`chunk=14974 wait=1387ms`) despite `wire=6.08 MB/s` aggregate throughput:
  1. **Control-Plane Serialization**: `AppState.startPlayback` blocked UI transition on `resolvePlaybackResource`; hovered/focused episodes and non-preloaded `DetailView` visits had zero control-plane or micro-chunk staging; `DonbyUHDServiceProvider.prewarmPlayback` skipped movies and ran domain resolution serially before `assets`.
  2. **2 MiB Tail-Crawl Cues Inversion**: Expanding `> 4 GiB` open tail prefetch to a single `2 MiB` sequential stream (`totalSize - 2 MiB`) caused `readDirectTailRange`'s `coveredByInFlight` check to block FFmpeg from issuing an exact-offset request for MKV `Cues` in the final `100-250 KiB`, forcing open to wait for `~1.8 MiB` of useless trailing video clusters on a throttled stream (`1.35s-1.98s`).
  3. **Post-Open Synchronous Seek Blackout (`753ms-4053ms`)**: `DKPlayer::open_with_tracks` synchronously executed `dk_shim_seek_format(fmt_ctx, start_sec, false)` before returning `0`, trapping `TurboStreamByteHandle` in `inOpenProbePhase` (low concurrency), serializing CoreAudio `AudioQueue` HAL init behind the remote seek, and triggering remote `Cues` seeks even on near-zero resumes (`start <= 2.5s`) that fell back to the `0.0s` keyframe in `Chunk 0`.
  4. **Single-Seek Gating & Slow-Lane Head-of-Line Starvation**: Applying the `0.55s` 2-stream scrub gate to single-click seeks plus `4`-chunk (`2 MiB`) coarse spans meant a single slow TCP flow (`< 450 KB/s`) holding `idx..<idx+4` starved `read()` while 3 fast lanes (`6+ MB/s`) jumped ahead to `idx+4..`.

## Rejected Approaches (DO NOT RE-INTRODUCE)
1. **Prefetching `totalSize - 2 MiB` as a single sequential stream while suppressing exact-offset Cues reads**:
   - **Why it failed (`v2.0.24` logs)**: Matroska `Cues` sit at the very end (`totalSize - 250 KiB .. totalSize`). Waiting for a shaped `0.8 MB/s` stream to crawl `1.8 MiB` before reaching `Cues` adds `~2.2s` to `avformat_open_input`.
2. **Synchronous `dk_shim_seek_format` inside `open_with_tracks` before `markInitialOpenCompleted()`**:
   - **Why it failed**: Deadlocks multi-lane ramp-up behind `inOpenProbePhase` and delays worker spawn + CoreAudio HAL setup by `1-4s` on cold resume.
3. **Unconditional `< 1.0s` pre-header cold rescue when no verified fast alternate lane exists**:
   - **Why rejected**: Violates [ADR-002](002-h2-adaptive-concurrency-and-l2-cache.md) on high-TTFB (`1.3-2.0s`) CDNs, causing duplicate request storms. Sub-second pre-header hedging is safe ONLY when `TurboStreamingSessionHub` confirms at least one alternate lane has verified low-TTFB/high-throughput telemetry.

## Accepted Design
1. **Persistent Route Warm Store & 4-Lane Edge Prewarm (`NetworkRouteWarmStore`, `TurboStreamingSessionHub+Prewarm`)**:
   - Persist `hostProtocolMultiplexed` (`7d` TTL), resolved edge origins (`300s` TTL), and `302` direct URLs (`1800s` TTL, `0600` permissions, auto-invalidated on `403/404/410`) under `DONBY_HOME`.
   - Track per-lane `ewmaTTFB`, `ewmaThroughputBps`, and `warmHosts`; proactively preconnect 4 TLS 1.3 / HTTP/2 lanes via `HEAD` (`45s` dedup, zero media bytes) and recycle zombie lanes whose speed drops `< 25%` of peer median (`< 450 KB/s`) twice consecutively.
2. **Tail-First 512 KiB Cues Sprint & 1-RTT 4-Lane Open Fan-Out (`TurboStreamByteHandle`)**:
   - Converge cold `Chunk 0` probe to `512 KiB` and prefetch ONLY the exact final `512 KiB` (`[totalSize - 512 KiB, totalSize - 1]`) on `Lane 2`. In `readDirectTailRange`, if an in-flight stream's received cursor is `> 192 KiB` behind the requested offset, immediately issue a `512 KiB` exact-offset bypass on a fast lane.
   - At `T = 0ms` (when direct/302 URL is known) or inside `handleEarlyRedirectResolved` (the instant origin `302` headers arrive, before CDN `206` returns), fan out `Chunk 1..2` (`Lane 1`), `Exact EOF 512 KiB` (`Lane 2`), and `Resume Anchor 1.5 MiB` (`Lane 3`) in parallel.
3. **Single-Seek Fine Striping, Tail-Trim Work-Stealing & Blocked-Reader Micro-Hedge**:
   - Track `recentSeekStreakCount` (`450ms` window): single-click seeks (`<= 1`) skip the 2-stream burst gate and stripe `2`-chunk (`1 MiB`) spans across warm lanes; rapid scrubbing (`>= 2`) engages a `0.35s` 2-stream gate.
   - Trim trailing chunks (`endChunkExclusive = idx + 1`) when a multi-chunk stream near playhead crawls `< max(480 KB/s, 0.4 * fastestLaneSpeed)`. When `read()` blocks on `urgentWaitingChunk` for `>= 300ms` with predicted remaining time `> 350ms` (or pre-header wait `> max(0.95s, smoothedTTFB * 1.4)` with a verified fast alternate lane, falling back to ADR-002's `>= 2.2s` otherwise), dispatch a `1`-chunk (`512 KiB`) cross-lane micro-hedge.
4. **Non-Blocking Kernel Initial Seek & Adaptive Audio Preroll (`KernelRust`)**:
   - Near-zero starts (`0.05 < start_sec <= 2.5`) skip remote `dk_shim_seek_format` and fast-forward locally from cached `Chunk 0` via `video_seek_drop_bits` / `audio_seek_drop_bits` + `AVDISCARD_NONREF`.
   - Far resumes (`start_sec > 2.5`) arm `initial_open_seek_pending` and return `0` immediately from `open_with_tracks`, overlapping `demux_worker` seek execution with `markInitialOpenCompleted()` and `audio_decode_worker` CoreAudio HAL setup.
   - Lower initial network `AudioQueue` preroll from `20_000` (`417ms`) to `10_240` samples (`213ms`) ONLY when `demux_worker` has already queued `>= 1.5s` of forward packets (`>= 24` video pkts, `>= 36` audio pkts, or `>= 1.5 MiB`).
5. **Intent-Aware Pre-Provisioning (`PlaybackIntentCoordinator`)**:
   - Synchronous `0ms` `ResolvedPlaybackResource` fast table (with automatic live `302` URL upgrade) backing `AppState.startPlayback` and `PlayerView.switchToEpisode`, fed by `DetailView` (`50ms` control-plane + `220ms` data-plane), episode hover/focus (`180ms` debounce, `1.5-2.5 MiB` micro-stage), Home `继续观看` top 2 control-plane warmup, and `>= 72%` (`buffer >= 12s`) next-episode micro-staging.
