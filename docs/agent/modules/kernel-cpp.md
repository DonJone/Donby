# Module Map: Playback Kernel (`DonbyKernelC`)

> Last synced: `v1.4.20`. Load this doc for FFmpeg demuxing, VideoToolbox decoding, AudioQueue A/V sync, seek flush, rebuffer cushions, and libass/PGS subtitles.

## 1. File Inventory & Core Symbols
- `Sources/DonbyKernelC/include/donby_kernel.h` (~204L)
  - Public C ABI bridging Swift <-> C++: `dk_player_create/destroy`, `dk_player_open_with_tracks`, `dk_player_set_custom_io`, `dk_player_play/pause/seek`, `dk_player_acquire_frame`, `dk_player_sync_subtitle_rgba`, `dk_player_should_yield_read`, subtitle/track setters, telemetry getters, plus VAD/alignment bridges (`DKSubtitleInterval`, `dk_player_copy_recent_audio_16k`, `dk_player_get_subtitle_intervals`, `dk_player_set_secondary_subtitle_time_scale`, `dk_player_get_secondary_subtitle_time_scale`).
- `Sources/DonbyKernelC/dk_engine.cpp` (~6350L)
  - Core struct `DKPlayer`: FFmpeg contexts (`AVFormatContext`, `AVCodecContext`, `SwrContext`), custom `AVIOContext`, `AudioQueueRef`, `ASS_Library`/`ASS_Renderer`/primary+secondary `ASS_Track`, `VideoFrameEntry` queue, `AudioChunk` queue, `PgsCue` queue, `vad_audio_ring` (`60s` @ `16kHz` mono under dedicated `vad_audio_mtx`), and `secondary_time_scale` (`1.0` default non-destructive affine timeline scale).
  - Key RAII & sync guards: `DKReaderGuard`, `AudioStartingGuard`, `SeekScopeGuard`.
  - Key functions:
    - `dk_check_dovi_fel(const uint8_t*, size_t)` — inline HEVC NAL 62/63 Dolby Vision RPU/FEL detector (replaced standalone `KernelRust` crate in `v1.4.12`).
    - `dk_required_audio_preroll_samples(const DKPlayer*)` — adaptive audio preroll (`24000` samples = `0.50s` when `rebuf == 0`, scales up on underrun rebuffers).
    - `dk_try_start_audio_queue_if_ready(DKPlayer*)` — primes & starts `AudioQueue`.
    - `dk_audio_decode_worker` / `dk_video_decode_worker` / `dk_demux_worker` — background pipeline threads.
    - `dk_player_acquire_frame` — called on CVDisplayLink thread; MUST NEVER block on CoreAudio or network I/O.

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
- **Subtitles, Pair-A Semantic Bilingual Engine & Unified Dual Compositor (`v1.4.9`)**:
  - **Pair-A Cinema Semantic Bilingual Engine** (`dk_try_render_paired_bilingual_locked`, `dk_build_paired_turns`, `dk_raster_paired_line_locked` using dedicated `paired_ass_renderer` + FNV `paired_layout_hash` 0ms frame cache):
    - Applies to single-track and dual-track text subtitles (`SRT/VTT`, standard dialogue `ASS`, dual-track `Text+Text`) when `unify_pingfang_font` is enabled and no special ASS effects (`\pos`, `\move`, `\org`, `\clip`, `\p1..9`, top alignments) are active (special ASS events fall back untouched to native `libass`).
    - Constant cinema typography anchored to `1200px` reference viewport height (`PingFang SC` Bold / `PingFangSC-Medium`, primary `58px` `#FFFFFF`, secondary `35px` (`0.60x`) classic warm orange-gold `#FFB22E`, outline `2.2/1.8`, shadow `1.0/0.9`); NEVER shrinks font size on multi-line/4-line cues.
    - Dual-track Anchor, Cluster Gap-Bridge & Bidirectional Safe Tail-Hold (`dual_anchor_mode`: `0=auto/English-preferred`, `1=primary`, `2=secondary`): Native Chinese media anchors to Chinese; English and third-language (JP/KR/EU) media anchor to English. Converts both tracks to **unified video display time (`pts_ms` applying `primary_delay_sec`, `secondary_delay_sec`, and `secondary_time_scale`)** and enforces three symmetric anti-flicker rules (`v1.4.19`, `v1.4.20`): (1) `±450ms` cluster entry/overhang snap, (2) `<=900ms` intra-cluster split gap bridging so 1-to-2, 2-to-1, and staggered 2-to-2 translation splits never leave a solo language hanging mid-dialogue, and (3) `<=1800ms` bidirectional safe tail-hold (clamped to the next non-concurrent cue's start) so shorter-ending cues (e.g. Chinese ending 0.8s before English) exit on the exact same frame as their paired counterpart without over-holding untranslated captions. Reserves the secondary baseline rail on 16:9 dual-track frames to prevent vertical bounce, and rescues dash-less 2-speaker counterparts (`dk_try_split_counterpart_by_anchor_ratio`).
    - Interleaved semantic pairing & smart reflow (`dk_reflow_non_dialogue_lines`, `dk_group_by_speaker_dash`): unwraps unnecessary streaming SRT/ASS hard line breaks within single-speaker turns (so short/medium English or CN+EN cues stay on one crisp line and only wrap cleanly via `WrapStyle: 0` when exceeding viewport width), groups wrapped 2-speaker continuations, re-pairs single-track block-separated (`CN1/CN2/EN1/EN2`), dual-track 2-speaker dialogue, and mismatched inline (`- A? - B.`) turns into `CN1+EN1` / `CN2+EN2` with exact per-line bounding-box placement (0px overlap).
    - Bottom-anchored growth & optical black-bar centering: single-turn cues sit optically centered inside bottom letterbox black bars (`42%` of spare bar height at default `92%`, minimum `26px` bottom bezel margin even at `100%`); multi-turn/4-line cues hold the bottom anchor (`28px` margin) and expand smoothly upward into the lower movie frame.
  - Symmetric primary + secondary slots: both slots independently support ASS/SRT (`libass` + `CFStringTransform`) AND PGS bitmap (`PgsCue`), enabling all 4 dual combinations (`Text+Text`, `PGS+Text`, `Text+PGS`, `PGS+PGS`).
  - Uses native `libass` viewport/letterbox pipeline (`dk_player_set_subtitle_viewport` -> `ass_set_margins`, `ass_set_use_margins(1)`, `ass_set_font_scale`, `ass_set_line_position`) and uncropped full-viewport PGS rendering so ASS/SRT/PGS subtitles render freely into black letterbox bars.
  - PGS pixel overrides: dark-outline-preserving HDR highlight normalization (`luma > 32` smooth ramp to 230, max `1.65x`), pale-yellow enrichment to `#FFB22E`, automatic orange-gold glyph tinting for secondary PGS tracks, and subtle outline boost.
  - Unified two-layer compositor (`DKRenderedSubLayer` + `dk_composite_dual_layers_locked`) driven by `secondary_scale` (default `0.60`), `dual_gap_px` (default `7.0`), `primary_on_top` (default `true` = CN-top / EN-bottom), and `dual_layout_mode` (`0` stacked / `1` split top+bottom).
  - **VAD Audio Tap & Non-Destructive Secondary Subtitle Affine Timing (`v1.4.17`)**: `dk_audio_decode_worker` decimates decoded audio (3:1 with remainder carryover to `16kHz` mono, blending `0.78*FC + 0.11*(FL+FR)` on 5.1/7.1 `FLTP@48kHz` for dialogue SNR) into `vad_audio_ring` under isolated `vad_audio_mtx` (cleared on seek/audio-switch/close/`>0.35s` PTS jump). Subtitle lookup evaluates `sec_pts = (pts - secondary_delay_sec) / secondary_time_scale`, supporting `23.976 <-> 25fps` drift correction non-destructively across ASS/SRT/PGS, style rebuilds, and instant undo.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **CVDisplayLink Thread Purity**: NEVER call `AudioQueuePrime`, `AudioQueueStart`, `dk_try_start_audio_queue_if_ready`, or blocking locks inside `dk_player_acquire_frame`. Fallback `AudioQueue` startup belongs on `dk_audio_decode_worker`.
2. **`audio_queue_starting` Serialization**: Every `AudioQueueStop` / `AudioQueueReset` path (seek, close, audio track switch, underrun rebuffer) MUST synchronize with `audio_queue_starting` so `AudioQueueStart` cannot race with teardown or pause.
3. **Audio EOF Clock Handoff**: When audio reaches EOF before video (common in MKV remuxes), master clock must seamlessly switch to monotonic fallback instead of freezing the final seconds.
4. **PGS/DVD Subtitle Probe Bypass (`v1.4.2`)**: Before `avformat_find_stream_info`, temporarily set `AVDISCARD_ALL` on subtitle streams and seed `1920x1080` on `0x0` `AV_CODEC_ID_HDMV_PGS_SUBTITLE` / `AV_CODEC_ID_DVD_SUBTITLE` streams, then immediately restore original `discard` and `0x0` dimensions after `avformat_find_stream_info` so FFmpeg never stalls reading 1-2 MiB waiting for a dialogue packet while keeping PGS/DVD decoding intact.
5. **URL Redaction**: Keep `Opening URL` log redacted (strip host/query/token).
6. **Single-Compile Kernel (`v1.4.14`)**: SwiftPM compiles `Sources/DonbyKernelC/dk_engine.cpp` directly at `-O3` (both Debug & Release) and caches it incrementally. Only run `./build_kernel.sh` when linking standalone C++ harnesses like `tmp/test_pair_a.cpp`.

## 4. Local Subtitle Format Test Matrix
- For real-server regression testing across `SRT+SRT` dual-track, single/external `ASS`, 4K HDR/letterbox `PGS`, mixed `PGS+Text`, `VobSub`, and `DVBSub`, see the git-ignored local catalog at `docs/agent/local/SUBTITLE_TEST_MEDIA.md` (never copy server names or item URLs into tracked docs).
