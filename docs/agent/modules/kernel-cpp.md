# Module Map: Playback Kernel (`DonbyKernelC` & `KernelRust`)

> Last synced: `v1.4.11`. Load this doc for FFmpeg demuxing, VideoToolbox decoding, AudioQueue A/V sync, seek flush, rebuffer cushions, libass/PGS subtitles, and Rust kernel helpers.

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
- **Subtitles, Pair-A Semantic Bilingual Engine & Unified Dual Compositor (`v1.4.9`)**:
  - **Pair-A Cinema Semantic Bilingual Engine** (`dk_try_render_paired_bilingual_locked`, `dk_build_paired_turns`, `dk_raster_paired_line_locked` using dedicated `paired_ass_renderer` + FNV `paired_layout_hash` 0ms frame cache):
    - Applies to single-track and dual-track text subtitles (`SRT/VTT`, standard dialogue `ASS`, dual-track `Text+Text`) when `unify_pingfang_font` is enabled and no special ASS effects (`\pos`, `\move`, `\org`, `\clip`, `\p1..9`, top alignments) are active (special ASS events fall back untouched to native `libass`).
    - Constant cinema typography anchored to `1200px` reference viewport height (`PingFang SC` Bold / `PingFangSC-Medium`, primary `58px` `#FFFFFF`, secondary `35px` (`0.60x`) classic warm orange-gold `#FFB22E`, outline `2.2/1.8`, shadow `1.0/0.9`); NEVER shrinks font size on multi-line/4-line cues.
    - Dual-track Anchor & Anti-Flicker Snap (`dual_anchor_mode`: `0=auto/English-preferred`, `1=primary`, `2=secondary`): Native Chinese media anchors to Chinese; English and third-language (JP/KR/EU) media anchor to English. Snaps overlapping non-anchor cue start/end edges within `±260ms` (and suppresses `<=260ms` leading/trailing overhangs) so dual lines enter/exit in lockstep, and uses anchor 2-speaker dashes to rescue dash-less single-line counterparts (`dk_try_split_counterpart_by_anchor_ratio` via sentence punctuation or ratio-matched spaces) without mis-splitting single-speaker inverted clauses.
    - Interleaved semantic pairing & smart reflow (`dk_reflow_non_dialogue_lines`, `dk_group_by_speaker_dash`): unwraps unnecessary streaming SRT/ASS hard line breaks within single-speaker turns (so short/medium English or CN+EN cues stay on one crisp line and only wrap cleanly via `WrapStyle: 0` when exceeding viewport width), groups wrapped 2-speaker continuations, re-pairs single-track block-separated (`CN1/CN2/EN1/EN2`), dual-track 2-speaker dialogue, and mismatched inline (`- A? - B.`) turns into `CN1+EN1` / `CN2+EN2` with exact per-line bounding-box placement (0px overlap).
    - Bottom-anchored growth & optical black-bar centering: single-turn cues sit optically centered inside bottom letterbox black bars (`42%` of spare bar height at default `92%`, minimum `26px` bottom bezel margin even at `100%`); multi-turn/4-line cues hold the bottom anchor (`28px` margin) and expand smoothly upward into the lower movie frame.
  - Symmetric primary + secondary slots: both slots independently support ASS/SRT (`libass` + `CFStringTransform`) AND PGS bitmap (`PgsCue`), enabling all 4 dual combinations (`Text+Text`, `PGS+Text`, `Text+PGS`, `PGS+PGS`).
  - Uses native `libass` viewport/letterbox pipeline (`dk_player_set_subtitle_viewport` -> `ass_set_margins`, `ass_set_use_margins(1)`, `ass_set_font_scale`, `ass_set_line_position`) and uncropped full-viewport PGS rendering so ASS/SRT/PGS subtitles render freely into black letterbox bars.
  - PGS pixel overrides: dark-outline-preserving HDR highlight normalization (`luma > 32` smooth ramp to 230, max `1.65x`), pale-yellow enrichment to `#FFB22E`, automatic orange-gold glyph tinting for secondary PGS tracks, and subtle outline boost.
  - Unified two-layer compositor (`DKRenderedSubLayer` + `dk_composite_dual_layers_locked`) driven by `secondary_scale` (default `0.60`), `dual_gap_px` (default `7.0`), `primary_on_top` (default `true` = CN-top / EN-bottom), and `dual_layout_mode` (`0` stacked / `1` split top+bottom).

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **CVDisplayLink Thread Purity**: NEVER call `AudioQueuePrime`, `AudioQueueStart`, `dk_try_start_audio_queue_if_ready`, or blocking locks inside `dk_player_acquire_frame`. Fallback `AudioQueue` startup belongs on `dk_audio_decode_worker`.
2. **`audio_queue_starting` Serialization**: Every `AudioQueueStop` / `AudioQueueReset` path (seek, close, audio track switch, underrun rebuffer) MUST synchronize with `audio_queue_starting` so `AudioQueueStart` cannot race with teardown or pause.
3. **Audio EOF Clock Handoff**: When audio reaches EOF before video (common in MKV remuxes), master clock must seamlessly switch to monotonic fallback instead of freezing the final seconds.
4. **PGS/DVD Subtitle Probe Bypass (`v1.4.2`)**: Before `avformat_find_stream_info`, temporarily set `AVDISCARD_ALL` on subtitle streams and seed `1920x1080` on `0x0` `AV_CODEC_ID_HDMV_PGS_SUBTITLE` / `AV_CODEC_ID_DVD_SUBTITLE` streams, then immediately restore original `discard` and `0x0` dimensions after `avformat_find_stream_info` so FFmpeg never stalls reading 1-2 MiB waiting for a dialogue packet while keeping PGS/DVD decoding intact.
5. **URL Redaction**: Keep `Opening URL` log redacted (strip host/query/token).
6. **Rebuild Requirement**: Any edit to `dk_engine.cpp` or `donby_kernel.h` requires `cmake --build /Users/don/git/Donby/build_kernel` (or `./build_kernel.sh`) BEFORE `swift build`.

## 4. Local Subtitle Format Test Matrix
- For real-server regression testing across `SRT+SRT` dual-track, single/external `ASS`, 4K HDR/letterbox `PGS`, mixed `PGS+Text`, `VobSub`, and `DVBSub`, see the git-ignored local catalog at `docs/agent/local/SUBTITLE_TEST_MEDIA.md` (never copy server names or item URLs into tracked docs).
