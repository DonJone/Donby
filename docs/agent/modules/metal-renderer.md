# Module Map: Metal EDR Video Renderer (`DonbyMetalRenderer`)

> Last synced: `v1.4.6`. Load this doc for CVDisplayLink presentation, Metal shaders, HDR10/Dolby Vision EDR tone mapping, GPU snapshots, first-frame callbacks, and subtitle overlay rendering.

## 1. File Inventory & Core Symbols
- `Sources/DonbyMetalRenderer/DKMetalVideoView.swift` (~1666L)
  - `DisplayLinkDriver` (~10) — manages `CVDisplayLink` callbacks and display refresh synchronization (60Hz/120Hz ProMotion).
  - `DKMetalPipelineSet` (~171) — compiled Metal render pipelines:
    - `pipelineVideoMaster` (NV12 / P010 10-bit bi-planar / YUV -> linear EDR `.rgba16Float` with PQ/HLG/Dolby Vision P5 & P8 RPU color uniforms `DKGpuColorUniformsMSL`).
    - `pipelineSubtitle` (independent linear-space alpha-blended subtitle overlay with HDR nit luminance scaling).
  - `DKMetalLayerView` (~266) — `NSView` hosting `CAMetalLayer` (`pixelFormat = .rgba16Float`, `wantsExtendedDynamicRangeContent = true`, `colorspace = extendedLinearDisplayP3` / SDR fallback).
  - `OffscreenMetalContext` (~1258) — GPU sRGB snapshot/thumbnail rendering for watch records and previews.
  - `DKMetalVideoView` (~1444) + `Coordinator` (~1501) + `SubtitleSyncBox` (~1523) — SwiftUI `NSViewRepresentable` bridge.

## 2. Key Rendering Behaviors
- **HDR10 & Dolby Vision EDR Pipeline**:
  - 10-bit bi-planar (`isTenBitBiPlanar`) and 8-bit `CVPixelBuffer` textures bound via `CVMetalTextureCache`.
  - Queries macOS `NSScreen.maximumExtendedDynamicRangeColorComponentValue` for EDR headroom calibration.
  - Subtitle luminance calibrated in nits (`203 / 250 / 400 nit` via `SubtitleHDRPeakNits`), auto-falling back on SDR displays.
- **Subtitle HUD Avoidance (`subtitleLiftY`) & Instant Paused Style Redraw (`v1.4.6`)**:
  - Smoothly interpolates vertical lift offset when the bottom player control bar is visible so subtitles do not collide with the scrubber.
  - `DKMetalVideoView.subtitleStyleRevision` flags `needsRedrawOnSameFrame = true` in `updateNSView`, bypassing paused DisplayLink throttling so dragging scale/position sliders updates subtitles at 60fps while paused.
- **Clean Player Detach & First-Frame Signal (`v1.4.0`)**:
  - `clearDisplayedFrame()` clears stale drawable content immediately when player detaches or becomes `nil` (no ghost frame from previous video).
  - `onFirstFrameRendered` callback fires on `MainActor` once the first real video frame is presented on screen, allowing `PlayerView` to dismiss the loading pill with zero black-frame gap.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **Zero Main-Thread / Render-Thread Blocking**: `renderLocked(_:colorUniforms:)` runs on the DisplayLink path; never perform synchronous SwiftUI state mutations or blocking I/O there (dispatch `onFirstFrameRendered` asynchronously to `MainActor`).
2. **Stale Frame Cleanup**: Always invoke `clearDisplayedFrame()` when switching/closing players so the previous item's last frame never flashes during new item startup.
3. **sRGB Snapshot Color Accuracy**: `OffscreenMetalContext` must convert HDR/EDR frames to sRGB for saved watch-record thumbnails (`v1.3.17` fix).
