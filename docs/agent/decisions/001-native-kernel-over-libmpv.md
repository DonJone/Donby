# ADR-001: Keep Custom Native Kernel (DonbyKernelC + Metal + Rust) Over libmpv

- **Status**: Accepted & Locked
- **Date**: 2026-11-19
- **Context**: During architecture benchmarking against third-party players (e.g. Moonglass/mpv-based players), we evaluated whether to migrate playback to `libmpv`.

## Decision
Keep and evolve Donby's custom playback stack:
1. `DonbyKernelC` (C++20 + FFmpeg + VideoToolbox + AudioToolbox `AudioQueue` + `libass`)
2. `DonbyMetalRenderer` (native Metal `.rgba16Float`, `wantsExtendedDynamicRangeContent = true`, custom DoVi P5/P8 RPU + EDR shaders, independent linear subtitle pipeline)
3. `KernelRust` (`libdonby_rs.a` for DoVi FEL detection and low-level helpers)
4. `DonbyNetwork` (`TurboCacheAndDownloadEngine` hooked into FFmpeg via custom `AVIOContext`)

## Rationale
- Full control over custom `AVIOContext` byte-stream scheduling (`TurboStreamByteHandle`), seek-epoch cancellation, and zero-copy L1/L2 chunk caching tailored for high-TTFB / rate-limited UHD/Emby CDNs.
- Full control over macOS Metal EDR headroom, Dolby Vision RPU tone-mapping, HDR subtitle nit calibration, and zero-stall CVDisplayLink frame presentation.
- Avoids `libmpv` black-box cache/demux heuristics and dylib bloat while still adopting proven UX/state-machine patterns (chapter skip, bounded health recovery, subtitle encoding detection, pinned offline chunk reuse).

## Consequences
- Every A/V sync, seek-flush, and AudioQueue lifecycle edge case is owned directly in `Sources/DonbyKernelC/dk_engine.cpp`. Always verify thread ownership and lock ordering in [../modules/kernel-cpp.md](../modules/kernel-cpp.md).
