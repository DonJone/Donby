# Donby Agent Knowledge Index (L0 Router)

> Read this file FIRST. Load only the specific L1 module doc(s) needed for your task.
> Keep this index under 100 lines.

## 1. Repository Overview
- **Product**: Donby — native macOS media player (macOS 13+, Apple Silicon & Intel x64) for Emby / Jellyfin / UHDNow / local media.
- **Stack**: SwiftUI + AppKit (`DonbyApp`, `DonbyCore`, `DonbyNetwork`, optional `DonbyUHDModule`), Metal EDR renderer (`DonbyMetalRenderer`), Rust + FFmpeg/VideoToolbox/AudioToolbox/libass playback kernel (`KernelRust` + C11 header shim `DonbyKernelC`; legacy C++20 baseline archived on `legacy/cpp-kernel`).
- **Current Version**: `2.1.7` (bound to every code commit + changelog entry + GitHub Release per `AGENTS.md`; default channel: `pre-release`).

## 2. Task-to-Module Routing Table

| If your task involves... | Read FIRST (L1) | Key Source Files |
| :--- | :--- | :--- |
| Streaming, seek latency, HTTP/2, Range, L1/L2 cache, offline downloads, Emby API, auto-updater | [modules/turbo-network.md](modules/turbo-network.md) | `Sources/DonbyNetwork/*` |
| Optional UHDNow Streaming API, dual-mode artwork, single-episode detail, lines/speedtest, Watch Party, Danmu | [modules/uhd-module.md](modules/uhd-module.md) | `Sources/DonbyUHDModule/*`, `Sources/DonbyApp/Modules/UHD/*` |
| Demuxing, decoding, A/V sync, AudioQueue, rebuffer, seek flush, libass/PGS subtitles, FFmpeg AVIO | [modules/kernel/INDEX.md](modules/kernel/INDEX.md) | `KernelRust/src/*`, `Sources/DonbyKernelC/*.c`, `Sources/DonbyKernelC/include/donby_kernel.h` |
| Video presentation, CVDisplayLink, HDR10/DoVi EDR, Metal shaders, first-frame callback, subtitle lift | [modules/metal-renderer.md](modules/metal-renderer.md) | `Sources/DonbyMetalRenderer/*` |
| Player surface, HUD, overlays, drawers, playback engine, track/subtitle alignment, controls | [modules/player/INDEX.md](modules/player/INDEX.md) | `Sources/DonbyApp/Player/*` |
| AppState, DetailView, 120Hz home/grid, artwork cache, Liquid Glass UI, server/files/settings/downloads views | [modules/app/INDEX.md](modules/app/INDEX.md) | `Sources/DonbyApp/AppState*.swift`, `DetailView*.swift`, `Components/*`, `Views/*`, `Server*.swift` |
| Core models, storage paths (`DONBY_HOME`), logger, AES-256-GCM credential vault, subtitle encoding/policies, version info, core tests | [modules/storage-core.md](modules/storage-core.md) | `Sources/DonbyCore/*`, `Tests/DonbyCoreTests/*` |
| Building, CMake, `.app` signing, Dock inode preservation, DMG/ZIP packaging, local release, CI | [modules/build-release.md](modules/build-release.md) | `build_app.sh`, `build_kernel.sh`, `scripts/*`, `.github/workflows/build-dmg.yml` |

## 3. Architecture Decision Records (L3)
- [decisions/001-native-kernel-over-libmpv.md](decisions/001-native-kernel-over-libmpv.md) — Why Donby keeps custom native kernel instead of `libmpv`.
- [decisions/002-h2-adaptive-concurrency-and-l2-cache.md](decisions/002-h2-adaptive-concurrency-and-l2-cache.md) — HTTP/2 concurrency tuning, EWMA TTFB rescue, async L2 persistence, and rejected approaches.
- [decisions/003-rust-kernel-migration.md](decisions/003-rust-kernel-migration.md) — Zero-dependency `KernelRust` rewrite architecture, C11 header shim rationale, and 4-phase parity plan (`legacy/cpp-kernel` -> `feat/rust-kernel` -> `v1.5.0`).
- [decisions/004-zero-serial-rtt-instant-play-v3.md](decisions/004-zero-serial-rtt-instant-play-v3.md) — Turbo Engine v3: 1-RTT 4-lane open fan-out, Tail-First 512 KiB Cues bypass, non-blocking kernel initial seek, tail-trim & blocked-reader micro-hedge, and `PlaybackIntentCoordinator`.
- [decisions/005-zero-crate-rust-media-data-plane-2a.md](decisions/005-zero-crate-rust-media-data-plane-2a.md) — Architecture 2A: `URLSession` thin transport + zero-crate `KernelRust` `GlobalSlabPool`, full APFS sparse `media.bin` store, `4..8`-lane BDP scheduler, and companion pacer.
- [decisions/006-intel-x64-and-hackintosh-support.md](decisions/006-intel-x64-and-hackintosh-support.md) — Intel older Mac & `x86_64` Hackintosh support: macOS 13 floor, discrete/iGPU Metal fixes, VT fallback + keyframe resync, strict multi-arch updater, and dual-arch CI.

## 4. Changelog Shards (L2)
- [changelog/v2.1.md](changelog/v2.1.md) — Active shard (`v2.1.0` onward: Stable milestone release & Architecture 2A zero-crate Rust media data plane).
- [changelog/v2.0.md](changelog/v2.0.md) — Archived shard (`v2.0.24`–`v2.0.25`: Turbo Engine v3 zero-serial-RTT instant-play, multi-lane streaming, playback-priority downloads).
- [changelog/v2.0.0-v2.0.23.md](changelog/v2.0.0-v2.0.23.md) — Archived shard (`v2.0.0`–`v2.0.23`: zero-dependency Rust playback kernel, C11 ABI shim, rating consensus, offline engine overhaul).
- [changelog/v1.4.md](changelog/v1.4.md) — Archived shard (`v1.4.22`–`v1.4.38`: frontend overhaul, `#03` hero strip, UHDNow module, GPU danmu, non-blue Liquid Glass).
- [changelog/v1.4.0-v1.4.21.md](changelog/v1.4.0-v1.4.21.md) — HTTP/2 adaptive streaming, async L2 cache, detail preloading, Silero VAD & Pair-A subtitles, AES-256-GCM vault, fast builds.
- [changelog/v1.3.29-v1.3.34.md](changelog/v1.3.29-v1.3.34.md) — 4K Remux seek, multi-MiB Range streaming, prewarm, Dock inode fixes.
- [changelog/v1.3.16-v1.3.28.md](changelog/v1.3.16-v1.3.28.md) — Modularization, 120Hz scrolling, subtitle suite, Turbo cache, offline library, updater, UHD startup cut.
- [changelog/v1.0-v1.3.15.md](changelog/v1.0-v1.3.15.md) — Initial release, HDR/DoVi EDR, Liquid Glass, artwork pipeline, icons, UHDNow, search.
- [changelog/TEMPLATE.md](changelog/TEMPLATE.md) — Mandatory entry template for new commits.

## 5. Local-Only Notes (Git-Ignored)
- `docs/agent/local/ENVIRONMENT_AND_BENCHMARKS.md` — Local test harness paths, real-server benchmark recipes, and `tmp/` handoff index. Never commit `docs/agent/local/`.
- `docs/agent/local/pm/BOARD.md` — Local Kanban board tracking active, in-review, and completed Task Cards (`DB-XXX`).
- `docs/agent/local/pm/WORKFLOW.md` — Multi-session VP / Dev / Reviewer / QA governance and handoff protocol.
- `docs/agent/local/SESSION_REGISTRY.md` — Active and archived local agent session registry.

## 6. Quick Commands
```bash
# L1 Fast incremental KernelRust (-O3) + C11 shim + Swift debug check (~1.3s warm)
./scripts/dev.sh build

# L2 Rust kernel + DonbyCore unit tests + agent doc-sync gate (isolated DONBY_HOME, ~1.5s warm)
./scripts/dev.sh test

# L3 Fast incremental Release build & in-place /Applications/Donby.app install (~3-5s incremental)
./build_app.sh

# Build KernelRust staticlib only (build_kernel/libdonby_kernel.a; content-hash cached)
./build_kernel.sh

# Pure standalone core build & test (physically excludes DonbyUHDModule and Modules/UHD)
DONBY_PURE=1 ./scripts/dev.sh build && DONBY_PURE=1 ./scripts/dev.sh test
```
