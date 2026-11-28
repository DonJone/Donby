# Module Map: Playback Kernel (`KernelRust` + `DonbyKernelC` ABI)

> Last synced: `v2.1.6` (C++20 baseline archived on `legacy/cpp-kernel`). Read [../../decisions/003-rust-kernel-migration.md](../../decisions/003-rust-kernel-migration.md), [../../decisions/004-zero-serial-rtt-instant-play-v3.md](../../decisions/004-zero-serial-rtt-instant-play-v3.md), [../../decisions/005-zero-crate-rust-media-data-plane-2a.md](../../decisions/005-zero-crate-rust-media-data-plane-2a.md), and [../../decisions/006-intel-x64-and-hackintosh-support.md](../../decisions/006-intel-x64-and-hackintosh-support.md) for architecture rationale.

## 1. Sub-Document Routing

| If your task involves... | Read FIRST (L2) |
| :--- | :--- |
| Player lifecycle, 9-step teardown, custom AVIO, demux, seek flush, track selection, C ABI, `dk_ffi_shim.c` | [lifecycle-and-demux.md](lifecycle-and-demux.md) |
| VideoToolbox decode, `CVDisplayLink` `acquire_frame`, `AudioQueue` sync/rebuffer, clock, DoVi, VAD | [video-and-audio.md](video-and-audio.md) |
| `libass` / PGS subtitle decoding, Pair-A semantic bilingual engine, secondary affine timing | [subtitles.md](subtitles.md) |

## 2. File Inventory

- `Sources/DonbyKernelC/include/donby_kernel.h` (**FROZEN C ABI**) — 39 `dk_*` public entrypoints (including `dk_player_is_seeking`).
- `Sources/DonbyKernelC/dk_ffi_shim_internal.h` (pure C11 internal header) — shared `DKShimStreamMeta`, callback typedefs, and cross-unit `dk_shim_*` prototypes.
- `Sources/DonbyKernelC/dk_ffi_shim.c` (pure C11) — `_Static_assert` ABI checks, `av_log` bridge, packet/frame alloc, format open with PGS/DVD fast-probe bypass, custom AVIO, stream/chapter metadata, seek/read, shared codec helpers.
- `Sources/DonbyKernelC/dk_ffi_video.c` (pure C11) — VideoToolbox hwaccel, `IOSurface`-backed `CVPixelBufferPool` + `SwsContext` fallback, HDR10/DoVi RPU `DKGpuColorUniforms` builder, thumbnail extraction.
- `Sources/DonbyKernelC/dk_ffi_audio.c` (pure C11) — audio decoder, `SwrContext` 48kHz stereo resampler + 5.1 downmix + VAD tap, `AudioQueue` C trampoline & playback/clock wrappers.
- `Sources/DonbyKernelC/dk_ffi_subtitle.c` (pure C11) — `CFStringTransform`, FFmpeg ASS/PGS/DVD subtitle packet decode, and `libass` struct accessors.
- `KernelRust/src/` (`donby_kernel_rs`, zero external Cargo deps -> `build_kernel/libdonby_kernel.a`):
  - `lib.rs` — Crate root, `LOG_CALLBACK`/`LIVE_PLAYERS`, `dk_rust_forward_ffmpeg_log`, `ReaderGuard`, URL normalization/redaction.
  - `player.rs` — `DKPlayer` (`#[repr(C)]`, including `initial_open_seek_pending`), sub-state structs, RAII guards, lock partial order docs.
  - `lifecycle.rs` — AVIO/interrupt thunks, `create_raw`/`destroy_raw`/`request_abort_raw`, `open_with_tracks`, 9-step `close_session`.
  - `demux.rs` — `demux_worker`, buffer backpressure, DoVi probe, `execute_pending_seek`.
  - `video.rs` — VT callbacks, software fallback, `video_decode_worker`, `acquire_frame`, `extract_video_thumbnail`.
  - `audio.rs` — AQ trampolines, `stop_reset_audio_queue`/`stop_dispose_audio_queue`, clock, `audio_decode_worker`, playback controls.
  - `audio_control.rs` — Per-player `"donby-aq-ctrl"` background worker for non-blocking `AudioQueuePause`/`AudioQueueStart` dispatch, seek barriers, and teardown sync.
  - `tracks.rs` — Auto-subtitle scoring, subtitle packet history, track/chapter getters, `select_track`.
  - `c_api.rs` — 39 `#[no_mangle] extern "C" fn dk_*` thin ABI wrappers (including `dk_player_is_seeking` and `dk_player_notify_metal_first_frame` `[StartupTiming]` emitter).
  - `c_api_net.rs` — `#[no_mangle] extern "C" fn dk_net_*` & `dk_player_attach_stream_bridge` C ABI wrappers for the 2A media data plane.
  - `net/` (zero-dependency 2A media data plane):
    - `net/mod.rs` — Darwin `SEEK_DATA`/`SEEK_HOLE` sparse extent helpers, physical-RAM-tiered budget sizing, and `PlaybackCompanionPacer`.
    - `net/slab.rs` — `GlobalSlabPool` fixed `512 KiB` page allocator with hard RAM cap and anchor pinning.
    - `net/disk_store.rs` — `DKChunkStore` sparse `media.bin` POSIX `pread`/`pwrite` storage and bounded background disk writer.
    - `net/disk_reconcile.rs` — `chunks.bitmap` binary codec, `SEEK_DATA` open-time reconciliation, legacy `.chk` folding, and tombstone removal.
    - `net/avio_bridge.rs` — `DKStreamBridge` in-kernel `AVIO` fast path (authoritative `cursor_offset` sync across fast/miss paths), partial slab ingestion, and `DKDownloadAssembler`.
  - `abi.rs` — `#[repr(C)]` ABI structs, `DKGpuColorUniforms::default_sdr()`, C-string helpers, `offset_of!` tests.
  - `ffi.rs` — `extern "C"` bindings + RAII `Drop` wrappers (`AvPacket`, `AvFrame`, `OwnedPixelBuffer`).
  - `clock.rs` — Monotonic ns clock helpers, `ClockState`, `SpeedTracker`.
  - `dovi.rs` — `check_dovi_rpu_or_el` (`check_dovi_fel` & `pq_norm_to_nits` are `#[cfg(test)]`).
  - `vad.rs` — `VadAudioRing` (60s @ 16kHz mono 3:1 decimator).
  - `subtitle/` (8 submodules; see [subtitles.md](subtitles.md) for task routing):
    - `subtitle/mod.rs` — `SubtitleEngine` struct/lifecycle/`Drop`/`mark_replayed` + unit tests.
    - `subtitle/pgs.rs` — FFmpeg packet decode (`DecodeCtx` callbacks) & PGS bitmap cue/pixel overrides.
    - `subtitle/ass_text.rs` — External SRT/VTT/ASS ingestion, `CFStringTransform`, ASS payload/tag sanitization.
    - `subtitle/ass_style.rs` — Style/viewport/affine time scale setters, header/style override application.
    - `subtitle/compositor.rs` — `prewarm_cjk_font`, `update_subtitle_rgba`, `raster_paired_line`, dual-layer RGBA blitting.
    - `subtitle/async_worker.rs` — Per-player `"donby-sub-worker"` thread for background `libass` CJK font prewarm, async `ass_render_frame` rasterization, and ready RGBA frame swaps for `CVDisplayLink`.
    - `subtitle/pair_a_render.rs` — Pair-A cinema bilingual layout engine & 1200px viewport anchoring.
    - `subtitle/pair_a_parse.rs` — Pair-A dialogue cleaning, speaker-dash grouping, semantic turn pairing.

## 3. Top Kernel Invariants (DO NOT BREAK)
1. **CVDisplayLink Purity**: Never call `try_start_audio_queue_if_ready` or `AudioQueueStart` inside `acquire_frame`.
2. **`audio_queue_starting` Serialization**: All `AudioQueueStop`/`Reset`/`Dispose` paths spin-wait `audio_queue_starting`.
3. **Lock Partial Order**: `LIVE_PLAYERS` -> `custom_io`; `demux_mtx` -> workers/queues/codecs; `audio_codec_mtx` -> `{vad_mtx, audio_chunks_mtx, video_queue_mtx, audio_buffers, audio_pkt_mtx, stats_mtx, workers_mtx}`.
4. **PGS/DVD Probe Bypass**: `dk_ffi_shim.c` temporarily sets `AVDISCARD_ALL` + `1920x1080` on PGS/DVD streams during `avformat_find_stream_info`.
5. **URL Redaction**: Strip host/query secrets in `Opening URL` logs via `redact_url_for_log`.
