# ADR-003: Rust Playback Kernel Migration Plan (`KernelRust`)

- **Status**: Completed & Merged to `main` as `v2.0.0` Pre-release (C++20 baseline archived at `legacy/cpp-kernel` @ `v1.4.38`)
- **Date**: 2026-11-24
- **Target Release**: `v2.0.0` (`pre-release`)

## 1. Branch & Baseline Topology

| Branch | Commit / State | Role |
| :--- | :--- | :--- |
| `legacy/cpp-kernel` | `9587490` (`v1.4.38` Stable) | Frozen archive of the 6,498-line C++20 kernel (`Sources/DonbyKernelC/dk_engine.cpp`, `CMakeLists.txt`). Reference via `git show legacy/cpp-kernel:Sources/DonbyKernelC/dk_engine.cpp`. |
| `main` | `9587490` (`v1.4.38` Stable) | Untouched production branch while `KernelRust` is reviewed on `feat/rust-kernel`; `/Applications/Donby.app` stays on Stable `v1.4.38` until merge/release confirmation. |
| `feat/rust-kernel` | Active migration branch | `dk_engine.cpp` and `CMakeLists.txt` removed; links `KernelRust` (`libdonby_kernel.a`) + pure-C11 header shim (`dk_ffi_shim.c`). |

## 2. Ponytail Architecture Principles (Smallest Complete Change)

1. **Zero Swift / Metal / Network Diff**:
   - Keep [donby_kernel.h](../../Sources/DonbyKernelC/include/donby_kernel.h) (204 lines, 7 `#[repr(C)]` structs/enums, 37 C functions) completely unchanged.
   - All 8 Swift callers (`PlayerView`, `DKMetalVideoView`, `AppState`, `DetailView`, `ArtworkComponents`, `DonbyApp`, `EmbyMainView`, `PlayerControls`), Metal EDR/DoVi shaders, `TurboStreamByteHandle` custom I/O callbacks, and `scripts/bundle_dylibs.py` require **zero source changes**.
2. **Zero External Cargo Crates (`[dependencies]` = empty)**:
   - Homebrew ships FFmpeg 8 (`libavformat 63.1.102`, `libavutil 61.1.102`) and `libass 0.17.5`; community crates (`ffmpeg-next`, `ffmpeg-sys-next`) lag SONAME bumps and require `bindgen` + `libclang` + 40+ crates.
   - `KernelRust` uses pure Rust `std` (`staticlib`, `panic = "abort"`, `-O3`, `codegen-units = 1`, no `lto` so Homebrew `rustc` LLVM emits native Mach-O objects rather than LLVM bitcode incompatible with Apple CLT tools; offline build in ~2.7s cold / ~0.01s cached) paired with a pure-C11 accessor file ([dk_ffi_shim.c](../../Sources/DonbyKernelC/dk_ffi_shim.c), compiled by SwiftPM `clang` with zero `-lc++`).
3. **Why Keep a Pure-C11 Shim (`dk_ffi_shim.c`)**:
   - Stable Rust cannot implement variadic C `va_list` callbacks required by `av_log_set_callback`.
   - FFmpeg's `libavutil/dovi_meta.h` explicitly marks `sizeof(AVDOVIRpuDataHeader)`, `sizeof(AVDOVIDataMapping)`, and `sizeof(AVDOVIColorMetadata)` outside public ABI; reading non-opaque FFmpeg/`libass` struct fields in `dk_ffi_shim.c` via `clang` prevents silent struct-offset UB across `brew upgrade ffmpeg` updates.
   - `_Static_assert` in `dk_ffi_shim.c` + `const` / `offset_of!` tests in [abi.rs](../../KernelRust/src/abi.rs) lock C<->Rust ABI layout at compile time (`DKGpuColorUniforms == 3088B`, `DKRuntimeStats == 160B`, `DKTrackInfo == 204B`, `DKChapterInfo == 152B`, `DKSubtitleStyleConfig == 64B`).

## 3. Implemented Module Map (`KernelRust/src/` + `dk_ffi_shim.c`)

| File | Replaces `dk_engine.cpp` | Core Responsibilities & RAII Ownership |
| :--- | :--- | :--- |
| `Sources/DonbyKernelC/dk_ffi_shim.c` | C struct & callback glue | `_Static_assert` ABI checks, `av_log` variadic bridge, PGS/DVD `0x0` `AVDISCARD_ALL` fast-probe bypass, VideoToolbox/SW `IOSurface` `CVPixelBufferPool` (`NV12`/`P010`), HDR10 + DoVi Profile 5/8 RPU polynomial/MMR `DKGpuColorUniforms`, `SwrContext` 5.1 center-boost + 48kHz mono VAD tap, `AudioQueue` C wrappers, `CFStringTransform`, and `libass` struct accessors. |
| `KernelRust/src/abi.rs` | `donby_kernel.h` | Exact `#[repr(C)]` ABI structs/enums, callback types, compile-time size/align/offset assertions. |
| `KernelRust/src/ffi.rs` | Raw pointer cleanup | `extern "C"` declarations + RAII `Drop` wrappers (`AvPacket`, `AvFrame`, `OwnedPixelBuffer`). |
| `KernelRust/src/dovi.rs` | `L477-820`, `L2430-2440` | HEVC NAL 62/63 RPU & FEL scanners, PQ EOTF (`pq_norm_to_nits`), default SDR `DKGpuColorUniforms`. |
| `KernelRust/src/vad.rs` | `L224-231`, `L329-403` | `VadAudioRing` (`60s @ 16kHz` mono, 3:1 remainder-carryover decimator with discontinuity reset). |
| `KernelRust/src/clock.rs` | `L232-328` | Monotonic nanosecond clock helpers, lock-free `ClockState`, smoothed `SpeedTracker`. |
| `KernelRust/src/subtitle.rs` | `L1656-2336`, `L3867-4326`, `L4515-6262` | `libass` primary/secondary/paired renderers, ASS-tag-preserving `CFStringTransform` (`Hans<->Hant`), `secondary_time_scale` affine timing, PGS bitmap cues + HDR/orange-gold pixel overrides, dual-layer RGBA compositor, and Pair-A Cinema Semantic Bilingual Engine (`1200px` typography, `+-450ms` snap, `<=900ms` gap bridge, `<=1800ms` safe tail-hold, FNV layout cache). |
| `KernelRust/src/lib.rs` | `L920-1655`, `L2337-3866`, `L6263-6498` | `DKPlayer`, `LIVE_PLAYERS` + `ReaderGuard` UAF protection, `demux_worker`, `video_decode_worker`, `audio_decode_worker`, `AudioQueue` startup/rebuffer/Pause-During-Seek serialization, `DONBY_TEST_MUTED` enforcement, non-blocking `dk_player_acquire_frame`, and all 37 `#[no_mangle] pub unsafe extern "C" fn dk_*` exports. |

## 4. Verification Status on `feat/rust-kernel`

- **Phase 0 (Branch Archival & Zero-Crate Build Wiring)** — **Completed** (`0257faf`)
- **Phase 1 (Demux, Custom AVIO, VideoToolbox/SW P010/NV12, HDR10/DoVi & Thumbnails)** — **Completed & Verified**
  - `dk_extract_video_thumbnail`, VideoToolbox HW decode, SW `IOSurface` Metal `CVPixelBufferPool`, 10-bit HEVC HDR10 (`PQ` / `BT.2020` / `1000 nits`), and custom `AVIOContext` (`read`/`seek`/`abort`/`close`) verified.
- **Phase 2 (`AudioQueue`, Master Clock, Seek Epoch, Paused Preview & Live VAD)** — **Completed & Verified**
  - Muted 5.1 AAC downmix + `16kHz` `VadAudioRing` capture, paused accurate seek preview (`DK_STATE_PAUSED` preserved), rate change, mid-stream track switch, and 8-cycle rapid `open -> play -> seek -> abort -> close -> destroy` concurrency stress verified (`25/25` smoke checks + `2/2` HDR10 HW/SW checks passed).
- **Phase 3 (`libass`, PGS Compositor & Pair-A Semantic Bilingual Engine)** — **Completed & Verified**
  - `tmp/test_pair_a.cpp` linked directly against `build_kernel/libdonby_kernel.a` + `dk_ffi_shim.c`: **15/15 cases, 32/32 assertions passed (`Total failures: 0`)**.
  - Plus **7/7** Rust unit tests (`cargo test`) and **20/20** `DonbyCoreTests` (`./scripts/dev.sh test`).
- **Phase 4 (Merge to `main` & `v1.5.0` Release)** — **Pending User Confirmation**
  - Merge `feat/rust-kernel` -> `main`, bump `1.4.38 -> 1.5.0` across all 5 version locations, start `docs/agent/changelog/v1.5.md`, and publish `./scripts/release_local.sh 1.5.0 --prerelease` (or `--stable` if requested).
