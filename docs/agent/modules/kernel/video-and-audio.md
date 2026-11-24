# Kernel Sub-Module: Video, Audio, Clock, DoVi & VAD

> Last synced: `v2.0.6`

## 1. Module Responsibilities
- `KernelRust/src/video.rs`: VideoToolbox failure callbacks (`is_vt_failed_thunk`, `on_sw_format_selected_thunk`), `fallback_video_to_software`, `video_decode_worker`, `acquire_frame` (`CVDisplayLink` presentation path), `extract_video_thumbnail`.
- `KernelRust/src/audio.rs`: `AudioQueue` C trampolines (`aq_fill_only_trampoline`, `aq_callback_trampoline`), serialized teardown helpers (`stop_reset_audio_queue`, `stop_dispose_audio_queue`), `get_audio_clock`, `get_master_clock`, `fill_audio_buffer`, `init_audio_queue`, `try_start_audio_queue_if_ready`, `start_audio_queue_with_buffered_data`, `audio_decode_worker`, and playback controls (`play`, `pause`, `set_rate`, `set_volume`).
- `KernelRust/src/clock.rs`: Monotonic nanosecond helpers (`steady_now_ns`, `elapsed_since_ns`), `pub(crate)` `ClockState` atomics, and smoothed `SpeedTracker`.
- `KernelRust/src/dovi.rs`: `check_dovi_rpu_or_el` (HEVC NAL 62/63 scanner used by `demux.rs`); `check_dovi_fel` and `pq_norm_to_nits` are `#[cfg(test)]` only (runtime DoVi RPU parsing and PQ EOTF run inside `Sources/DonbyKernelC/dk_ffi_video.c`).
- `KernelRust/src/vad.rs`: `VadAudioRing` (60s @ 16kHz mono 3:1 center-weighted decimator fed by `audio_decode_worker`).
- `Sources/DonbyKernelC/dk_ffi_video.c`: VideoToolbox hwaccel callbacks, `IOSurface`-backed `CVPixelBufferPool` + `SwsContext` software fallback, HDR10/HLG & Dolby Vision P5/P8 RPU `DKGpuColorUniforms` builder, and thumbnail extraction.
- `Sources/DonbyKernelC/dk_ffi_audio.c`: FFmpeg audio decoder, `SwrContext` 48kHz stereo float resampler + 5.1 downmix + center-weighted VAD mono tap, and `AudioQueue` C trampoline & playback/clock wrappers.

## 2. Critical Threading & Sync Invariants
1. **CVDisplayLink Thread Purity (`acquire_frame`)**:
   - Only acquire leaf `video_queue_mtx`, check `audio_queue_starting` non-blockingly, and nudge `audio_decode_cv.notify_one()`.
   - NEVER call `try_start_audio_queue_if_ready`, `AudioQueuePrime`, or `AudioQueueStart` inside `acquire_frame`.
2. **`audio_queue_starting` Serialization**:
   - `start_audio_queue_with_buffered_data` guards `AudioQueuePrime` + `AudioQueueStart` with `AudioStartingGuard` (`audio_queue_starting`) and rechecks `state == Playing && !is_seeking()` after prime.
   - `stop_reset_audio_queue` and `stop_dispose_audio_queue` spin-wait `audio_queue_starting` before calling `dk_shim_aq_stop_reset` / `dk_shim_aq_stop_dispose`.
3. **Audio EOF Mutex Release**:
   - `audio_decode_worker` explicitly calls `drop(ac)` (releasing `audio_codec_mtx`) on audio EOF before invoking `start_audio_queue_with_buffered_data()`.
4. **Master Clock Handoff**:
   - Driven by `AudioQueue` hardware sample time once calibrated; falls back seamlessly to monotonic system clock when silent, HAL-disabled, or at audio EOF.
5. **Underrun & Rebuffer**:
   - Continuous silence underrun detection runs above `video_queue.is_empty()` in `acquire_frame` so audio starvation triggers rebuffer cushion even while video frames remain queued.
