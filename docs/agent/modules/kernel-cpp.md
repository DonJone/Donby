# Module Map: Playback Kernel (`DonbyKernelC` & `KernelRust`)

> Last synced: `v1.4.2`. Load this doc for FFmpeg demuxing, VideoToolbox decoding, AudioQueue A/V sync, seek flush, rebuffer cushions, libass/PGS subtitles, and Rust kernel helpers.

## 1. File Inventory & Core Symbols
- `Sources/DonbyKernelC/include/donby_kernel.h` (~192L)
  - Public C ABI bridging Swift <-> C++: `dk_player_create/destroy`, `dk_player_open/open_with_tracks`, `dk_player_set_custom_io`, `dk_player_play/pause/seek`, `dk_player_acquire_frame`, `dk_player_should_yield_read`, subtitle/track setters, telemetry getters.
- `Sources/DonbyKernelC/dk_engine.cpp` (~4488L)
  - Core struct `DKPlayer` (line ~117): FFmpeg contexts (`AVFormatContext`, `AVCodecContext`, `SwrContext`), custom `AVIOContext`, `AudioQueueRef`, `ASS_Library`/`ASS_Renderer`/primary+secondary `ASS_Track`, `VideoFrameEntry` queue, `AudioChunk` queue, `PgsCue` queue.
  - Key RAII & sync guards: `DKReaderGuard` (~314), `AudioStartingGuard` (~1033), `SeekScopeGuard` (~2081).
  - Key functions:
    - `dk_required_audio_preroll_samples(const DKPlayer*)` — adaptive audio preroll (`24000` samples = `0.50s` when `rebuf == 0`, scales up on underrun rebuffers).
    - `dk_try_start_audio_queue_if_ready(DKPlayer*)` — primes & starts `AudioQueue`.
    - `dk_audio_decode_worker` / `dk_video_decode_worker` / `dk_demux_worker` — background pipeline threads.
    - `dk_player_acquire_frame` — called on CVDisplayLink thread; MUST NEVER block on CoreAudio or network I/O.
- `KernelRust/src/lib.rs` (~241L) + `KernelRust/include/donby_rs.h` (~34L)
  - `dk_rs_check_dovi_fel` (active in `dk_engine.cpp` to detect Dolby Vision Profile 7 FEL).
  - `dk_rs_cache_*` (`CacheInner` ring/arena cache, available as static lib `libdonby_rs.a`).

## 2. Threading, Sync & State Machine
- **Master Clock**: Driven by `AudioQueue` hardware playback timeline (with monotonic fallback when silent/audio-EOF so video never stalls at audio EOF).
- **First-Frame & AudioQueue Startup Synchronization (`v1.4.0`)**:
  - Video presentation holds the first frame until `audio_queue_started == true` (with silent-audio fallback) to prevent first-frame A/V pop or freeze.
  - `audio_queue_started = true` is set ONLY AFTER `AudioQueuePrime` + `AudioQueueStart` return `noErr`, guarded by atomic `audio_queue_starting` and a post-prime `state == DK_STATE_PLAYING` recheck (fixes Pause-During-Seek race where audio could leak after user paused).
  - Leading misaligned A/V samples/frames are trimmed on startup and after seek.
- **Seek Lifecycle**:
  - `dk_player_seek` increments seek epoch, sets seeking flag (`dk_is_seeking`), aborts/yields in-flight custom AVIO reads (`dk_player_should_yield_read`), flushes FFmpeg & decode queues, serializes `AudioQueueStop`/`AudioQueueReset` against `audio_queue_starting`, and resumes cleanly.
  - Paused seek decodes and presents a single preview frame without starting `AudioQueue`.
- **Underrun & Rebuffer**:
  - Continuous silence underrun detection runs **above** `video_queue.empty()` so audio starvation triggers rebuffer cushion even if video frames are still queued.
  - Rebuffer pauses clock cleanly until `dk_required_audio_preroll_samples` is refilled.
- **Subtitles**:
  - Supports embedded ASS/SRT (via `libass`, dual primary + secondary `ASS_Track`, `CFStringTransform` live Simplified/Traditional conversion before `ass_process_chunk`), external text subtitles, and bitmap PGS (`PgsCue` / `PgsBitmapRect`).

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **CVDisplayLink Thread Purity**: NEVER call `AudioQueuePrime`, `AudioQueueStart`, `dk_try_start_audio_queue_if_ready`, or blocking locks inside `dk_player_acquire_frame`. Fallback `AudioQueue` startup belongs on `dk_audio_decode_worker`.
2. **`audio_queue_starting` Serialization**: Every `AudioQueueStop` / `AudioQueueReset` path (seek, close, audio track switch, underrun rebuffer) MUST synchronize with `audio_queue_starting` so `AudioQueueStart` cannot race with teardown or pause.
3. **Audio EOF Clock Handoff**: When audio reaches EOF before video (common in MKV remuxes), master clock must seamlessly switch to monotonic fallback instead of freezing the final seconds.
4. **PGS/DVD Subtitle Probe Bypass (`v1.4.2`)**: Before `avformat_find_stream_info`, temporarily set `AVDISCARD_ALL` on subtitle streams and seed `1920x1080` on `0x0` `AV_CODEC_ID_HDMV_PGS_SUBTITLE` / `AV_CODEC_ID_DVD_SUBTITLE` streams, then immediately restore original `discard` and `0x0` dimensions after `avformat_find_stream_info` so FFmpeg never stalls reading 1-2 MiB waiting for a dialogue packet while keeping PGS/DVD decoding intact.
5. **URL Redaction**: Keep `Opening URL` log redacted (strip host/query/token).
6. **Rebuild Requirement**: Any edit to `dk_engine.cpp` or `donby_kernel.h` requires `cmake --build /Users/don/git/Donby/build_kernel` (or `./build_kernel.sh`) BEFORE `swift build`.
