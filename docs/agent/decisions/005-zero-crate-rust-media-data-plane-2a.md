# ADR-005: Hybrid Rust Media Data Plane Architecture 2A (`URLSession` Thin Transport + Zero-Dependency `KernelRust` Data Core)

- **Status**: Accepted (Implemented in `v2.1.1`)
- **Date**: 2026-11-27
- **Context**: Profiling 4K HEVC/DoVi Remux streaming (`10–20 MB/s` peak) and gigabit offline downloads (`80–100 MB/s`) on `v2.1.0` exposed five remaining data-plane bottlenecks:
  1. `TurboStreamingSessionHub` capped independent TCP lanes at `4`, and HTTP/2 concurrency stayed locked at `4` whenever wire throughput exceeded `4.5 MB/s` (below 4K Remux bitrate on `1.5 MB/s` per-stream shaped CDNs).
  2. Steady-state streaming lookahead capped Range spans at `4–6 MiB`, wasting `30%–50%` link capacity on `350–600 ms` TTFB edges.
  3. Unpinned streaming caches wrote out-of-order chunks to individual `chunks/<idx>.chk` spill files and folded them into `media.bin` (`2x` disk writes + `1x` read + APFS metadata churn).
  4. `AsyncThrowingStream<Data, Error>` + `Data.removeSubrange` in download workers and `FileHandle` allocations in `TieredAssetChunkStore` caused heap allocation churn and coupled disk backpressure with the player `AVIO` lock.
  5. Remote playback unconditionally halted background downloads even on high-headroom broadband links with `>= 32 MiB` forward buffer.

## Rejected Approaches
1. **Rewriting `DonbyNetwork` in C11 + `libcurl`**:
   - Loses `CFNetwork` native macOS system proxy/PAC/Keychain root CA integration and production HTTP/3 (QUIC) support (system `libcurl` lacks HTTP/3), while re-introducing raw-pointer UAF hazards across concurrent seek/abort/teardown paths retired in [ADR-003](003-rust-kernel-migration.md).
2. **Full-Stack Userspace HTTP/TLS in `KernelRust` (`tokio` + `reqwest`/`hyper` + `rustls`)**:
   - Adds `~200` Cargo crates (`+60s` clean build, `+8–15 MB` binary size), breaks the zero-external-crate guarantee of `KernelRust`, and still requires custom `SystemConfiguration` / PAC bridging on macOS.

## Accepted Design (Architecture 2A)
1. **Physical-RAM-Tiered `GlobalSlabPool` (`KernelRust/src/net/slab.rs`)**: Fixed `512 KiB` reusable page pool auto-tiered via `sysctlbyname("hw.memsize")` (`<16G -> 96 MiB`, `16..32G -> 160 MiB`, `32..64G -> 256 MiB`, `>=64G -> 384 MiB`), protecting `Chunk 0..3` and final `2` EOF chunks with zero steady-state heap churn.
2. **Full APFS Sparse Direct-Write `DKChunkStore` (`disk_store.rs`, `disk_reconcile.rs`)**: Both pinned and unpinned assets write directly to `media.bin` via POSIX `pwrite` (`FileExt::write_at`) and read directly into destination buffers via `pread` (`FileExt::read_at`), persisted via atomic `chunks.bitmap` (FNV-64 verified against `SEEK_DATA`/`SEEK_HOLE`) with tombstone `invalidate_for_removal()` and legacy `.chk` one-shot folding.
3. **In-Kernel `AVIO` Fast Path & Zero-Copy Assemblers (`avio_bridge.rs`)**: `DKPlayer` attaches `DKStreamBridge` (`dk_player_attach_stream_bridge`) so L1 slab, L2 `pread`, and active partial-slab reads execute inside `KernelRust` with zero Swift FFI crossings; `TurboStreamingSessionHub` and `DonbyDownloadManager` push `URLSessionDataDelegate` `withUnsafeBytes` slices directly into Rust `SlabPage`s.
4. **Adaptive `4..8` Lanes, `8–32 MiB` BDP Spans & `PlaybackCompanionPacer`**: Expands `TurboStreamingSessionHub` to `4` warm + `4` lazy `ephemeral` lanes (`maxStreamLaneCount = 8`), scales steady-state Range spans to `8 / 16 / 32 MiB` once `leadCachedChunks >= 16`, and paces a single low-priority companion download worker via token bucket whenever active playback holds `>= 64` chunks (`32 MiB`) of healthy cushion.
