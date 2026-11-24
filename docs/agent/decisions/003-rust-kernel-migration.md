# ADR-003: Rust Playback Kernel Migration Plan (`KernelRust`)

- **Status**: In Progress on `feat/rust-kernel` (C++20 baseline archived at `legacy/cpp-kernel` @ `v1.4.38`)
- **Date**: 2026-11-24
- **Target Release**: `v1.5.0` (merge to `main` only after full playback + subtitle parity gates pass)

## 1. Branch & Baseline Topology

| Branch | Commit / State | Role |
| :--- | :--- | :--- |
| `legacy/cpp-kernel` | `3afc491` (`v1.4.38` Stable) | Frozen archive of the 6,498-line C++20 kernel (`Sources/DonbyKernelC/dk_engine.cpp`, `CMakeLists.txt`). Reference via `git show legacy/cpp-kernel:Sources/DonbyKernelC/dk_engine.cpp`. |
| `main` | `3afc491` (`v1.4.38` Stable) | Untouched production branch while `KernelRust` reaches feature parity; `/Applications/Donby.app` stays on Stable `v1.4.38` during intermediate work. |
| `feat/rust-kernel` | Active migration branch | `dk_engine.cpp` and `CMakeLists.txt` removed; links `KernelRust` (`libdonby_kernel.a`) + thin C11 header shim (`dk_ffi_shim.c`). |

## 2. Ponytail Architecture Principles (Smallest Complete Change)

1. **Zero Swift / Metal / Network Diff**:
   - Keep [donby_kernel.h](../../Sources/DonbyKernelC/include/donby_kernel.h) (204 lines, 7 `#[repr(C)]` structs/enums, 37 C functions) completely unchanged.
   - All 8 Swift callers (`PlayerView`, `DKMetalVideoView`, `AppState`, `DetailView`, `ArtworkComponents`, `DonbyApp`, `EmbyMainView`, `PlayerControls`), Metal EDR/DoVi shaders, `TurboStreamByteHandle` custom I/O callbacks, and `scripts/bundle_dylibs.py` require **zero source changes**.
2. **Zero External Cargo Crates (`[dependencies]` = empty)**:
   - Homebrew ships FFmpeg 8 (`libavformat 63.1.102`) and `libass 0.17.5`; community crates (`ffmpeg-next`, `ffmpeg-sys-next`) lag SONAME bumps and require `bindgen` + `libclang` + 40+ crates.
   - The kernel only calls **64 FFmpeg functions**, **19 `libass` functions**, and **42 Apple CoreVideo/AudioToolbox/CF/CG functions**.
   - `KernelRust` uses pure Rust `std` (`staticlib`, `panic = "abort"`, `-O3`, `codegen-units = 1`, no `lto` so Homebrew `rustc` LLVM emits native Mach-O objects rather than LLVM bitcode incompatible with Apple CLT tools; ~0.4s cold compile, offline) paired with a ~200-line pure-C11 accessor file ([dk_ffi_shim.c](../../Sources/DonbyKernelC/dk_ffi_shim.c), compiled by SwiftPM `clang` with zero `-lc++`).
3. **Why Keep a Thin Pure-C11 Shim (`dk_ffi_shim.c`)**:
   - Stable Rust cannot implement variadic C `va_list` callbacks required by `av_log_set_callback`.
   - Reading non-opaque C struct fields (`AVStream`, `AVCodecParameters`, `AVFrame`, `AVDOVIMetadata`, `AVSubtitle`, `ASS_Track`, `ASS_Style`, `ASS_Event`, `ASS_Image`) via C11 inline/helper accessors compiled directly against Homebrew's installed headers prevents silent struct-offset UB whenever `brew upgrade ffmpeg` updates FFmpeg headers.
   - `_Static_assert` in `dk_ffi_shim.c` + `const` / `offset_of!` tests in [abi.rs](../../KernelRust/src/abi.rs) lock C<->Rust ABI layout at compile time (`DKGpuColorUniforms == 3088B`, `DKRuntimeStats == 160B`, `DKTrackInfo == 204B`, `DKChapterInfo == 152B`, `DKSubtitleStyleConfig == 64B`).

## 3. Subsystem Decomposition (`dk_engine.cpp` 6,498L -> `KernelRust/src/` ~3,100L)

| Rust Module | Replaces `dk_engine.cpp` Lines | Core Responsibilities & RAII Ownership |
| :--- | :--- | :--- |
| `src/abi.rs` *(done)* | `donby_kernel.h` | Exact `#[repr(C)]` ABI structs/enums, callback types, compile-time size/align/offset assertions. |
| `src/dovi.rs` *(FEL + PQ done; RPU in Phase 1)* | `L477-820`, `L2430-2440` | HEVC NAL 63 FEL scan, PQ EOTF, HDR10 MasteringDisplay/MaxCLL + Dolby Vision Profile 5/8 RPU polynomial & MMR reshaping -> `DKGpuColorUniforms`. |
| `src/vad.rs` *(done)* | `L224-231`, `L329-403`, `L4225-4250` | Isolated `Mutex<VadAudioRing>` (`60s @ 16kHz` mono, 3:1 remainder-carryover decimator with `0.78*FC + 0.11*(FL+FR)` surround dialogue weighting). |
| `src/ffi.rs` *(Phase 1)* | Raw pointer cleanup across file | `extern "C"` declarations + RAII `Drop` wrappers (`AvPacket`, `AvFrame`, `AvCodecCtx`, `AvFormatInput`, `CvPixelBuffer`, `CfType`) eliminating manual leak paths on seek/abort. |
| `src/demux.rs` *(Phase 1)* | `L427-454`, `L2337-3620`, `L6365-6498` | Custom `AVIOContext` (`TurboStreamByteHandle` read/seek/abort + `in_flight_readers` RAII guard + `dk_player_should_yield_read`), PGS/DVD `0x0` `AVDISCARD_ALL` probe bypass, track/chapter tables, bounded packet queues, `sub_pkt_history` instant switch ring, `dk_extract_video_thumbnail`. |
| `src/video.rs` *(Phase 1)* | `L455-476`, `L822-919`, `L1471-1655`, `L4327-4514` | VideoToolbox hardware decode (`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`) + automatic `IOSurface` `CVPixelBufferPool` (`sws_scale`) software fallback, lock-free/non-blocking `dk_player_acquire_frame` for `CVDisplayLink`. |
| `src/audio.rs` *(Phase 2)* | `L920-1470`, `L3621-3684` | `SwrContext` float32 interleaved resampling (dynamic TrueHD/DTS-HD/EAC3 reconfig), `AudioQueue` 4x8192B output, `MasterClock` (hardware sample-time + audio-EOF monotonic handoff), `audio_queue_starting` serialization + post-prime `DK_STATE_PLAYING` recheck, adaptive preroll (`24,000` samples base). |
| `src/subtitle.rs` *(Phase 3)* | `L1656-2336`, `L3867-4326`, `L4515-6262` | `libass` primary/secondary/paired renderers, ASS-tag-preserving `CFStringTransform` (`Hans<->Hant`), `secondary_time_scale` affine timing, PGS bitmap cues + HDR/orange-gold pixel overrides, dual-layer RGBA compositor, and Pair-A Cinema Semantic Bilingual Engine (`1200px` typography, `+-450ms` snap, `<=900ms` gap bridge, `<=1800ms` safe tail-hold, FNV layout cache). |

## 4. Phased Execution Plan & Verification Gates

### Phase 0 — Branch Archival, Zero-Crate Scaffold & Build Plumbing (Completed)
- Archived C++20 kernel to `origin/legacy/cpp-kernel` (`3afc491`).
- Removed `dk_engine.cpp` & `CMakeLists.txt` on `feat/rust-kernel`.
- Created `KernelRust/` (`abi.rs`, `dovi.rs`, `vad.rs`, `lib.rs` exporting all 37 `dk_*` symbols) + `Sources/DonbyKernelC/dk_ffi_shim.c` + `build_kernel.sh` / `Package.swift` / `scripts/dev.sh` / `build_app.sh` / CI integration.
- **Gate**: `cargo test`, `./scripts/dev.sh build`, and `./scripts/dev.sh test` pass with 0 errors.

### Phase 1 — Demux, Custom AVIO, VideoToolbox/SW Decode, DoVi RPU & Thumbnails
- Implement `ffi.rs`, complete `dovi.rs` (`AVDOVIMetadata` RPU reshaping via `dk_ffi_shim.c`), `demux.rs`, and `video.rs` (initially driven by monotonic clock before Phase 2 attaches `AudioQueue`).
- **Invariants**:
  - PGS/DVD `AVDISCARD_ALL` + `1920x1080` seed around `avformat_find_stream_info` so 4K Remuxes open without reading 1-2 MiB searching for dialogue packets.
  - Redact host/query/tokens in `Opening URL` log lines.
  - `dk_player_acquire_frame` NEVER blocks on I/O, `AudioQueue`, or codec locks.
- **Gate**: `cargo test` + headless CLI harness opens local/remote H.264, HEVC HDR10, and DoVi Profile 5/8 streams, yields non-null `CVPixelBufferRef` frames + valid `DKGpuColorUniforms`, and `dk_extract_video_thumbnail` returns a valid `CGImageRef`.

### Phase 2 — AudioToolbox `AudioQueue`, Master Clock, Seek Epoch & Live VAD
- Implement `audio.rs` and full seek-epoch flush across `demux.rs` / `video.rs` / `audio.rs`.
- **Invariants**:
  - Hold first video frame until `audio_queue_started == true` (with silent/disabled-HAL fallback).
  - Serialize every `AudioQueueStop` / `AudioQueueReset` against `audio_queue_starting`, and recheck `state == Playing` after `AudioQueuePrime` before `AudioQueueStart` (prevents Pause-During-Seek audio leak).
  - Run continuous underrun detection above `video_queue.is_empty()`; hand off master clock to monotonic timer on audio EOF so trailing video frames never freeze.
  - Paused seek decodes and presents one preview frame without starting `AudioQueue`.
- **Gate**: `DONBY_TEST_MUTED=1` `bench_uhd_edge_cases.swift` passes (warmup, paused seek preview + resume, pause-during-seek race, `0.0s` seek, near-EOF seek, mid-playback audio track switch, Silero VAD `dk_player_copy_recent_audio_16k` alignment).

### Phase 3 — Subtitles (`libass`, PGS Compositor & Pair-A Semantic Bilingual Engine)
- Implement `subtitle.rs` + `dk_ffi_shim.c` `AVSubtitle` / `ASS_Track` / `ASS_Image` accessors.
- **Invariants**:
  - Preserve all 4 dual combinations (`Text+Text`, `PGS+Text`, `Text+PGS`, `PGS+PGS`), uncropped letterbox viewport margins, `secondary_time_scale`, `dk_player_get_subtitle_intervals`, and `sub_pkt_history` zero-seek track switching.
  - Exact Pair-A rules (`1200px` reference scale, never shrink 4-line cues, `+-450ms` cluster snap, `<=900ms` intra-cluster split bridge, `<=1800ms` bidirectional safe tail-hold, speaker-dash grouping, counterpart ratio split).
- **Gate**: Compile & link existing `tmp/test_pair_a.cpp` directly against `build_kernel/libdonby_kernel.a` -> **21/21 checks pass** across all 12 bilingual cases, plus real-media matrix (`SRT+SRT`, `ASS`, `PGS+Text`).

### Phase 4 — Full Stress Audit, Merge to `main` & `v1.5.0` Release
- Run 50-round open/seek/close leak & race audit (`VerifyTurbo`, `bench_uhd_audit.swift`, `bench_uhd_edge_cases.swift`).
- Merge `feat/rust-kernel` -> `main`, bump version `1.4.38 -> 1.5.0` across all 5 version locations, start `docs/agent/changelog/v1.5.md`, sync `docs/agent/modules/kernel-cpp.md` (renaming/updating for `KernelRust`), and publish `./scripts/release_local.sh 1.5.0 --prerelease`.
