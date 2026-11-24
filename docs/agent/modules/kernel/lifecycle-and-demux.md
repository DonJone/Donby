# Kernel Sub-Module: Lifecycle, Demux, Tracks & C ABI

> Last synced: `v2.0.4`

## 1. Module Responsibilities
- `KernelRust/src/lib.rs`: Crate root, module declarations, `LOG_CALLBACK` / `LIVE_PLAYERS` registry, `dk_rust_forward_ffmpeg_log`, `ReaderGuard`, URL normalization/redaction (`normalize_path_or_url`, `redact_url_for_log`).
- `KernelRust/src/player.rs`: `DKPlayer` (`#[repr(C)]`, 70 fields), sub-state structs (`VideoQueueState`, `SwVideoState`, `AudioCodecState`, `SubHistoryState`, `WorkerHandles`), RAII guards (`AudioStartingGuard`, `SeekScopeGuard`), state/rate/volume/stats accessors.
- `KernelRust/src/lifecycle.rs`: FFmpeg interrupt & custom AVIO C callbacks (`interrupt_callback_thunk`, `avio_read_thunk`, `avio_seek_thunk`), `create_raw`, `destroy_raw`, `request_abort_raw`, `open_with_tracks`, and 9-step `close_session`.
- `KernelRust/src/demux.rs`: `demux_worker` packet loop, buffer cap backpressure, EOF handling, DoVi NAL 62/63 probing, and `execute_pending_seek` (seek flush + `stop_reset_audio_queue`).
- `KernelRust/src/tracks.rs`: `score_auto_subtitle_stream`, subtitle packet history (`record_sub_pkt_history`, `replay_sub_pkt_history`), track/chapter enumeration, `select_track`, `select_secondary_subtitle_track`.
- `KernelRust/src/c_api.rs`: All 37 `#[no_mangle] pub unsafe extern "C" fn dk_*` entrypoints matching `Sources/DonbyKernelC/include/donby_kernel.h`.
- `KernelRust/src/abi.rs`: Frozen C ABI `#[repr(C)]` structs/enums, compile-time size/align assertions, `offset_of!` tests, `DKGpuColorUniforms::default_sdr()`, and C-string helpers (`cchar_array_to_string`, `write_str_to_cchar`).
- `KernelRust/src/ffi.rs`: `extern "C"` bindings for `dk_ffi_shim.c` and `libass`, plus RAII wrappers (`AvPacket`, `AvFrame`, `OwnedPixelBuffer`).
- `Sources/DonbyKernelC/include/donby_kernel.h`: Frozen C ABI header declaring 7 `#[repr(C)]` structs/enums and 37 `dk_*` functions.
- `Sources/DonbyKernelC/dk_ffi_shim.c`: Pure C11 FFmpeg/VideoToolbox/AudioToolbox/`libass` shim, `_Static_assert` ABI checks, `av_log` variadic bridge, PGS/DVD subtitle probe bypass.

## 2. Mandatory Lock Partial Order
1. `LIVE_PLAYERS` -> `custom_io` (never acquire `LIVE_PLAYERS` while holding `custom_io`).
2. `demux_mtx` -> `{video_pkt_mtx, audio_pkt_mtx, video_codec_mtx, audio_codec_mtx, sub_mtx, sub_hist_mtx, video_queue_mtx, audio_chunks_mtx, vad_mtx, speed_mtx}`.
3. `audio_codec_mtx` -> `{vad_mtx, audio_chunks_mtx, video_queue_mtx, audio_buffers, audio_pkt_mtx, stats_mtx, workers_mtx}`.
4. `video_codec_mtx` -> `stats_mtx`.

## 3. 9-Step Teardown Order (`close_session`)
1. Atomic `is_closing` CAS (`false -> true`).
2. Set `abort_requested` + invoke `custom_io` `abort_cb`.
3. Drain `in_flight_readers` to zero.
4. Wake all condvars (`demux_cv`, `video_decode_cv`, `audio_decode_cv`, `video_frame_cv`) and join worker threads.
5. `stop_dispose_audio_queue()` (spin-waits `audio_queue_starting`, then disposes `AudioQueue`).
6. Clear packet, frame, audio chunk, subtitle history, and VAD queues.
7. Close audio/video codecs, `SwrContext`, `SwsContext`/pool, and `SubtitleEngine` stream state.
8. Close `format_ctx` / `custom_avio_ctx` and invoke `custom_io` `close_cb`.
9. Reset stream indices and set state to `DKPlayerState::Idle`.
