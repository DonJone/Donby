# ADR-006: Intel Older Mac & x86_64 Hackintosh Support (`v2.1.3`)

## Status
Accepted (`v2.1.3`)

## Context
Donby originally targeted `macOS 14+` on `arm64` (Apple Silicon). Supporting older Intel Macs (including 2017 Ventura Macs, dual-GPU 15"/16" MacBook Pros, Xeon `iMacPro1,1`/`MacPro7,1`, and OCLP-patched 2012-2017 Macs) and `x86_64` Hackintoshes (OpenCore/Clover with discrete AMD Polaris/Vega/Navi GPUs, headless QuickSync iGPUs, broken `AppleGVA`/`WhateverGreen` VDA setups, and Broadcom Wi-Fi setups pinned to macOS 13 Ventura) revealed six systemic incompatibilities:

1. **OS Floor**: `Package.swift` and `build_app.sh` required `macOS 14.0`, and SwiftUI views used `.focusEffectDisabled()`, two-argument `.onChange(of:)`, and `.onKeyPress(...)` without `@available(macOS 14.0, *)` shims.
2. **Discrete GPU & Dual-GPU Metal Hazards**: `DKMetalLayerView+Rendering.swift` hardcoded `storageMode = .shared` on `MTLTextureDescriptor`, which is invalid for 2D textures on discrete GPUs (`device.hasUnifiedMemory == false`), and read `.rgba8Unorm_srgb` staging textures without `MTLBlitCommandEncoder.synchronize(resource:)`. `DKMetalLayerView` also ignored display-attached GPUs (`CGDirectDisplayCopyCurrentMetalDevice`) and unconditionally forced 64-bpp `.rgba16Float` EDR on low-power Intel iGPUs.
3. **VideoToolbox Silent/Async Failure**: `KernelRust/src/video.rs` only triggered software fallback on `avcodec_send_packet < 0`, leaving streams black when `VTDecompressionSession` failed asynchronously in `avcodec_receive_frame < 0` or produced null `CVPixelBuffer`s. `dk_ffi_video.c` also routed AV1 and 10-bit H.264 to VideoToolbox on `x86_64` and ran `SwsContext` `SWS_BILINEAR` on common software `YUV420P`/`YUV420P10LE` frames.
4. **Updater Cross-Arch Hazard**: `AppVersionComparator` fell back to any `.dmg`/`.app.zip` asset when the requested architecture was absent, risking an `x86_64` client downloading and replacing itself with an `arm64` binary.
5. **Hackintosh SMBIOS Edge Case**: Incomplete Hackintosh SMBIOS configurations can omit `IOPlatformUUID` on `IOPlatformExpertDevice`.
6. **Single-Arch Build & CI**: `build_kernel.sh`, `build_app.sh`, `scripts/bundle_dylibs.py`, `scripts/package_dmg.sh`, and `.github/workflows/build-dmg.yml` assumed host-native `arm64` and `/opt/homebrew`.

## Decision
1. **macOS 13.0 (Ventura) Floor**: Lowered `Package.swift`, `build_kernel.sh`, and `build_app.sh` deployment targets to `13.0`, added `donbyFocusEffectDisabled()`, `donbyOnChange(of:perform:)`, and `DonbyPlayerKeyPressModifier` in `DonbyApp` (relying on `PlayerView`'s existing `NSEvent.addLocalMonitorForEvents` on macOS 13).
2. **Display-Driven & Discrete-Safe Metal Renderer**:
   - Use `dev.hasUnifiedMemory ? .shared : .managed` for `MTLTextureDescriptor`s and synchronize `.managed` staging textures via `MTLBlitCommandEncoder.synchronize(resource:)` before `getBytes`.
   - Select the GPU driving the window's screen via `CGDirectDisplayCopyCurrentMetalDevice` and reconfigure `CAMetalLayer`/pipelines/subtitle ring cleanly on screen/GPU changes.
   - Use `.bgra8Unorm_srgb` (32-bpp SDR Display P3) on `x86_64` low-power Intel iGPUs without EDR headroom and as a fallback if `.rgba16Float` pipeline creation fails on legacy OCLP Metal shims.
3. **Resilient VideoToolbox Fallback & Fast Software Packing**:
   - Bypass VideoToolbox immediately on `__x86_64__` for AV1 and Hi10p H.264.
   - Trigger `fallback_video_to_software()` on `receive_frame < 0` and null `CVPixelBuffer`s during early decode, with `signal_seek_request` keyframe resync when the IDR packet was already consumed.
   - Raise software decoder thread clamp to `12` and add `-O3` auto-vectorizable direct `YUV420P -> NV12` and `YUV420P10LE -> P010` packers in `dk_ffi_video.c`.
4. **Strict Multi-Arch Auto-Updater & Mach-O Pre-Replace Guard**:
   - Add `DonbyAppInfo.preferredUpdateArchitecture` (Rosetta-aware), strict `classifyAssetArchitecture` matching (never crossing `arm64` vs `x86_64`), multi-arch `platforms` support in `latest.json`, and `DonbyAppInfo.machOBinarySupportsArchitecture` verification prior to `spawnDetachedAppReplacer`.
5. **Credential Vault SMBIOS Fallback**: `EncryptedFileVaultBackend` falls back from `IOPlatformUUID` to trimmed `IOPlatformSerialNumber` before `"donby-fallback-host"`.
6. **Hybrid Dual-Arch Release Pipeline**: Support `DONBY_ARCH` (`arm64` / `x86_64` / `universal`) across build/packaging scripts, and upgrade `.github/workflows/build-dmg.yml` to build missing architectures on `macos-15` (`arm64`) and `macos-15-intel` (`x86_64`) and merge `SHA256SUMS.txt` and `latest.json` into the existing GitHub Release without altering its channel flags.

## Consequences
- `release_local.sh` on Apple Silicon continues to publish `arm64` in seconds with zero CI queue, while tag pushes automatically trigger `macos-15-intel` to build and attach `x86_64` artifacts to the same release.
- `x86_64` and macOS 13 Ventura users receive native builds, safe updates, and automatic software decode fallback without black screens or discrete-GPU crashes.
