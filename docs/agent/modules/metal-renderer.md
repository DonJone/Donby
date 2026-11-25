# Module Map: Metal EDR Video Renderer (`DonbyMetalRenderer`)

> Last synced: `v2.0.10`. Load this doc for CVDisplayLink presentation, Metal shaders, HDR10/Dolby Vision EDR tone mapping, GPU snapshots, first-frame callbacks, and subtitle overlay rendering.

## 1. File Inventory & Core Symbols
- `Sources/DonbyMetalRenderer/DKMetalShadersAndPipeline.swift`
  - `DKVertexUniforms` — vertex scale, subtitle lift/nit parameters, and UV crop uniforms.
  - `DKMetalPipelineSet` — compiled & cached Metal render pipelines (`videoPipeline` for NV12/P010/DoVi -> linear EDR `.rgba16Float`, `bgraPipeline` fallback, and `subPipeline` for linear-space alpha-blended subtitles).
  - `DKMetalLayerView.metalShaderSource` & `prewarmPipelines()` — embedded MSL shaders (`vertex_main`, `fragment_video_master`, `fragment_bgra`, `fragment_subtitle`) and startup pipeline prewarming.
- `Sources/DonbyMetalRenderer/DKMetalLayerView.swift`
  - `DKMetalLayerView` — `NSView` hosting `CAMetalLayer` (`pixelFormat = .rgba16Float`, `wantsExtendedDynamicRangeContent = true`, `colorspace = extendedLinearDisplayP3` / SDR fallback), stored state (`hasExternalDisplayLink`, `lastRenderSkipReason`), EDR headroom observer, layout/drawable sizing, subtitle lift/occlusion controls, and `setupMetal()`.
- `Sources/DonbyMetalRenderer/DKMetalLayerView+Rendering.swift`
  - `DKMetalLayerView` rendering extension — `CVMetalTextureCache` frame upload (`renderLocked`, `renderBiPlanar`, `renderBGRA`), skip diagnostics (`_lastRenderSkipReason`), 3-slot subtitle `MTLTexture` ring (`updateSubtitleOverlay`), `subtitleViewportMetrics`, and `OffscreenMetalContext` / `renderOffscreenCGImage` for GPU sRGB snapshot/thumbnail rendering.
- `Sources/DonbyMetalRenderer/DKMetalVideoView.swift`
  - `DisplayLinkDriver` — manages `CVDisplayLink` callbacks and `.common`-mode 60Hz timer fallback.
  - `DKMetalVideoView` + `Coordinator` + `SubtitleSyncBox` — SwiftUI `NSViewRepresentable` bridge, `onRenderDiagnostic` startup stall logger, and `dk_player_notify_metal_first_frame` dispatch.

## 2. Key Rendering Behaviors
- **HDR10 & Dolby Vision EDR Pipeline**:
  - 10-bit bi-planar (`isTenBitBiPlanar`) and 8-bit `CVPixelBuffer` textures bound via `CVMetalTextureCache`.
  - Queries macOS `NSScreen.maximumExtendedDynamicRangeColorComponentValue` for EDR headroom calibration.
  - Subtitle luminance calibrated in nits (`203 / 250 / 400 nit` via `SubtitleHDRPeakNits`), auto-falling back on SDR displays.
- **Full-Viewport Letterbox Subtitles, HUD Avoidance & Instant Paused Redraw (`v1.4.7`)**:
  - `DKMetalLayerView.subtitleViewportMetrics(videoWidth:videoHeight:)` computes the full-window subtitle canvas (normalized `<=1920px` long edge) and exact letterbox margins, passes them to `dk_player_set_subtitle_viewport`, and draws the subtitle quad at full NDC `scale = (1, 1)` so ASS/SRT/PGS subtitles display freely in black bars.
  - Smoothly interpolates full-viewport `currentSubtitleLiftNDC` when the bottom player control bar is visible so subtitles do not collide with the scrubber.
  - `DKMetalVideoView.subtitleStyleRevision` flags `needsRedrawOnSameFrame = true` in `updateNSView`, bypassing paused DisplayLink throttling so dragging scale/position sliders updates subtitles at 60fps while paused.
  - `DKMetalLayerView` rotates subtitle uploads across a 3-slot `MTLTexture` ring (`subtitleTextures`, `v1.4.21`) so CPU `replace(region:)` never mutates an in-flight GPU texture on 120Hz ProMotion displays.
- **Clean Player Detach & First-Frame Signal (`v1.4.0`+)**:
  - `clearDisplayedFrame()` clears stale drawable content immediately when player detaches or becomes `nil` (no ghost frame from previous video).
  - `onFirstFrameRendered` fires on `MainActor` once the first real video frame is presented on screen, and `dk_player_notify_metal_first_frame` emits the single-line `[StartupTiming]` summary once per open.
  - `hasExternalDisplayLink` prevents `layout()`, `subtitleHDRPeakNits`, and `didChangeScreenParametersNotification` from calling `renderLastPixelBuffer()` (`metalLayer.nextDrawable()`) synchronously on the main thread while `CVDisplayLink` is active — avoiding 1-second `tryLockBusy` starvation during macOS's 60Hz EDR headroom ramp on initial process launch.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **Zero Main-Thread / Render-Thread Blocking & Coordinator Lock Hygiene**: `renderLocked(_:colorUniforms:)` runs on the DisplayLink path; never invoke synchronous `renderLastPixelBuffer()` from main-thread notifications/layout while `hasExternalDisplayLink` is `true` (set `needsRedrawOnSameFrame = true` instead), and never perform synchronous SwiftUI state mutations there. All cross-thread `Coordinator` state (`_player`, `onFirstFrameRendered`, `onRenderDiagnostic`, `lastPts`, `lastBufferPtr`, `lastSubSerial`, `didNotifyFirstFrame`) MUST be synchronized with `playerLock`.
2. **Stale Frame Cleanup**: Always invoke `clearDisplayedFrame()` when switching/closing players so the previous item's last frame never flashes during new item startup.
3. **sRGB Snapshot Color Accuracy**: `OffscreenMetalContext` must convert HDR/EDR frames to sRGB for saved watch-record thumbnails (`v1.3.17` fix).
