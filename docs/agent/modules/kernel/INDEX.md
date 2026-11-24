# Module Map: Playback Kernel (`KernelRust` + `DonbyKernelC` ABI)

> Last synced: `v2.0.4` (C++20 baseline archived on `legacy/cpp-kernel`). Read [../../decisions/003-rust-kernel-migration.md](../../decisions/003-rust-kernel-migration.md) for migration rationale.

## 1. Sub-Document Routing

| If your task involves... | Read FIRST (L2) |
| :--- | :--- |
| Player lifecycle, 9-step teardown, custom AVIO, demux, seek flush, track selection, C ABI, `dk_ffi_shim.c` | [lifecycle-and-demux.md](lifecycle-and-demux.md) |
| VideoToolbox decode, `CVDisplayLink` `acquire_frame`, `AudioQueue` sync/rebuffer, clock, DoVi, VAD | [video-and-audio.md](video-and-audio.md) |
| `libass` / PGS subtitle decoding, Pair-A semantic bilingual engine, secondary affine timing | [subtitles.md](subtitles.md) |

## 2. File Inventory

- `Sources/DonbyKernelC/include/donby_kernel.h` (`204L`, **FROZEN C ABI**) — 37 `dk_*` public entrypoints.
- `Sources/DonbyKernelC/dk_ffi_shim.c` (`1,979L`, pure C11) — `_Static_assert` ABI checks, `av_log` bridge, VideoToolbox/`IOSurface` pool, `AudioQueue`/Swr wrappers, FFmpeg/`libass` accessors.
- `KernelRust/src/` (`donby_kernel_rs`, zero external Cargo deps -> `build_kernel/libdonby_kernel.a`):
  - `lib.rs` (`142L`) — Crate root, `LOG_CALLBACK`/`LIVE_PLAYERS`, `dk_rust_forward_ffmpeg_log`, `ReaderGuard`, URL normalization/redaction.
  - `player.rs` (`434L`) — `DKPlayer` (`#[repr(C)]`, 70 fields), sub-state structs, RAII guards, lock partial order docs.
  - `lifecycle.rs` (`687L`) — AVIO/interrupt thunks, `create_raw`/`destroy_raw`/`request_abort_raw`, `open_with_tracks`, 9-step `close_session`.
  - `demux.rs` (`348L`) — `demux_worker`, buffer backpressure, DoVi probe, `execute_pending_seek`.
  - `video.rs` (`520L`) — VT callbacks, software fallback, `video_decode_worker`, `acquire_frame`, `extract_video_thumbnail`.
  - `audio.rs` (`626L`) — AQ trampolines, `stop_reset_audio_queue`/`stop_dispose_audio_queue`, clock, `audio_decode_worker`, playback controls.
  - `tracks.rs` (`367L`) — Auto-subtitle scoring, subtitle packet history, track/chapter getters, `select_track`.
  - `c_api.rs` (`440L`) — 37 `#[no_mangle] extern "C" fn dk_*` thin ABI wrappers.
  - `abi.rs` (`244L`) — `#[repr(C)]` ABI structs, `DKGpuColorUniforms::default_sdr()`, C-string helpers, `offset_of!` tests.
  - `ffi.rs` (`483L`) — `extern "C"` bindings + RAII `Drop` wrappers (`AvPacket`, `AvFrame`, `OwnedPixelBuffer`).
  - `clock.rs` (`124L`) — Monotonic ns clock helpers, `ClockState`, `SpeedTracker`.
  - `dovi.rs` (`79L`) — `check_dovi_rpu_or_el` (`check_dovi_fel` & `pq_norm_to_nits` are `#[cfg(test)]`).
  - `vad.rs` (`118L`) — `VadAudioRing` (60s @ 16kHz mono 3:1 decimator).
  - `subtitle.rs` (`3,663L`) — `libass`/PGS renderers & Pair-A bilingual engine (Phase 2 split target).

## 3. Top Kernel Invariants (DO NOT BREAK)
1. **CVDisplayLink Purity**: Never call `try_start_audio_queue_if_ready` or `AudioQueueStart` inside `acquire_frame`.
2. **`audio_queue_starting` Serialization**: All `AudioQueueStop`/`Reset`/`Dispose` paths spin-wait `audio_queue_starting`.
3. **Lock Partial Order**: `LIVE_PLAYERS` -> `custom_io`; `demux_mtx` -> workers/queues/codecs; `audio_codec_mtx` -> `{vad_mtx, audio_chunks_mtx, video_queue_mtx, audio_buffers, audio_pkt_mtx, stats_mtx, workers_mtx}`.
4. **PGS/DVD Probe Bypass**: `dk_ffi_shim.c` temporarily sets `AVDISCARD_ALL` + `1920x1080` on PGS/DVD streams during `avformat_find_stream_info`.
5. **URL Redaction**: Strip host/query secrets in `Opening URL` logs via `redact_url_for_log`.
