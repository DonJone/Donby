# Donby Agent Knowledge Index (L0 Router)

> Read this file FIRST. Load only the specific L1 module doc(s) needed for your task.
> Keep this index under 100 lines.

## 1. Repository Overview
- **Product**: Donby — native macOS media player (macOS 14+, Apple Silicon) for Emby / Jellyfin / UHDNow / local media.
- **Stack**: SwiftUI + AppKit (`DonbyApp`, `DonbyCore`, `DonbyNetwork`), Metal EDR renderer (`DonbyMetalRenderer`), C++20/FFmpeg/VideoToolbox/AudioToolbox/libass playback kernel (`DonbyKernelC`).
- **Current Version**: `1.4.20` (bound to every code commit + changelog entry + GitHub Release per `AGENTS.md`; default channel: `pre-release`).

## 2. Task-to-Module Routing Table

| If your task involves... | Read FIRST (L1) | Key Source Files |
| :--- | :--- | :--- |
| Streaming, seek latency, HTTP/2, Range, L1/L2 cache, offline downloads, Emby/UHD API, auto-updater | [modules/turbo-network.md](modules/turbo-network.md) | `Sources/DonbyNetwork/TurboCacheAndDownloadEngine.swift`, `EmbyClient.swift`, `UHDStreamClient.swift`, `OfflineMediaLibrary.swift`, `AppUpdateManager.swift` |
| Demuxing, decoding, A/V sync, AudioQueue, rebuffer, seek flush, libass/PGS subtitles, FFmpeg AVIO | [modules/kernel-cpp.md](modules/kernel-cpp.md) | `Sources/DonbyKernelC/dk_engine.cpp`, `include/donby_kernel.h` |
| Video presentation, CVDisplayLink, HDR10/DoVi EDR, Metal shaders, first-frame callback, subtitle lift | [modules/metal-renderer.md](modules/metal-renderer.md) | `Sources/DonbyMetalRenderer/DKMetalVideoView.swift` |
| Player HUD, scrubber, seek debounce, AppState, Liquid Glass UI, 120Hz home/grid, artwork cache, views | [modules/app-player-ui.md](modules/app-player-ui.md) | `Sources/DonbyApp/PlayerView.swift`, `AppState.swift`, `DetailView.swift`, `Components/*`, `Views/*` |
| Core models, storage paths (`DONBY_HOME`), logger, AES-256-GCM credential vault, subtitle encoding/policies, version info, core tests | [modules/storage-core.md](modules/storage-core.md) | `Sources/DonbyCore/*`, `Tests/DonbyCoreTests/DonbyCoreTests.swift` |
| Building, CMake, `.app` signing, Dock inode preservation, DMG/ZIP packaging, local release, CI | [modules/build-release.md](modules/build-release.md) | `build_app.sh`, `build_kernel.sh`, `scripts/*`, `.github/workflows/build-dmg.yml` |

## 3. Architecture Decision Records (L3)
- [decisions/001-native-kernel-over-libmpv.md](decisions/001-native-kernel-over-libmpv.md) — Why Donby keeps custom C++/Metal kernel instead of `libmpv`.
- [decisions/002-h2-adaptive-concurrency-and-l2-cache.md](decisions/002-h2-adaptive-concurrency-and-l2-cache.md) — HTTP/2 concurrency tuning, EWMA TTFB rescue, async L2 persistence, and rejected approaches.

## 4. Changelog Shards (L2)
- [changelog/v1.4.md](changelog/v1.4.md) — Active shard (`v1.4.0` onward).
- [changelog/v1.3.29-v1.3.34.md](changelog/v1.3.29-v1.3.34.md) — 4K Remux seek, multi-MiB Range streaming, prewarm, Dock inode fixes.
- [changelog/v1.3.16-v1.3.28.md](changelog/v1.3.16-v1.3.28.md) — Modularization, 120Hz scrolling, subtitle suite, Turbo cache, offline library, updater, UHD startup cut.
- [changelog/v1.0-v1.3.15.md](changelog/v1.0-v1.3.15.md) — Initial release, HDR/DoVi EDR, Liquid Glass, artwork pipeline, icons, UHDNow, search.
- [changelog/TEMPLATE.md](changelog/TEMPLATE.md) — Mandatory entry template for new commits.

## 5. Local-Only Notes (Git-Ignored)
- `docs/agent/local/ENVIRONMENT_AND_BENCHMARKS.md` — Local test harness paths, real-server benchmark recipes, and `tmp/` handoff index. Never commit `docs/agent/local/`.

## 6. Quick Commands
```bash
# L1 Fast incremental Swift + C++20 (-O3) debug check (~1.3s incremental)
./scripts/dev.sh build

# L2 Core unit tests (isolated DONBY_HOME, ~0.9s warm)
./scripts/dev.sh test

# L3 Fast incremental Release build & in-place /Applications/Donby.app install (~3-5s incremental)
./build_app.sh

# Standalone C++ static lib (only needed for standalone C++ harnesses like tmp/test_pair_a.cpp; mtime-cached)
./build_kernel.sh
```
