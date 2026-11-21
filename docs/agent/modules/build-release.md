# Module Map: Build, Packaging & Release Pipeline

> Last synced: `v1.4.14`. Load this doc for compiling Swift/C++, bundling dylibs, signing `/Applications/Donby.app`, DMG/ZIP packaging, channel-aware local GitHub Releases, and CI.

## 1. File Inventory
- `Package.swift` — SwiftPM manifest compiling `DonbyKernelC/dk_engine.cpp` directly at `-O3` (single compilation, cached by SwiftPM, no `-ldonby_kernel` duplicate link) plus `DonbyCoreTests`.
- `scripts/dev.sh` (~58L) — Fast local CLI wrapper (`build` / `test` / `app` / `release`) that auto-selects valid CLT SDK, uses `--build-system native` (avoiding Swift 6.4 `swiftbuild` 54s no-op cache-invalidation bug), and passes CLT `Testing.framework` search paths + isolated `DONBY_HOME`.
- `CMakeLists.txt` + `build_kernel.sh` — Standalone mtime-cached C++20 `libdonby_kernel.a` builder (only needed for standalone C++ test harnesses; skips compile when up to date).
- `build_app.sh` (~144L) — Incremental Release build: uses `--build-system native` + multi-core incremental `-O` (`-no-whole-module-optimization -incremental`, opt-in `DONBY_WMO=1`), skips up-to-date `AppIcon.icns`, preserves `/Applications/Donby.app` inode and cached `Contents/Frameworks/` dylibs, signs app bundle (`codesign --force --sign -`), and verifies `--deep --strict`.
- `scripts/bundle_dylibs.py` (~248L) — Batches `install_name_tool` flags per binary, reuses valid cached `@rpath` dylibs in `Contents/Frameworks/` across incremental installs, prunes stale dylibs, signs only modified dylibs in parallel, and verifies zero external Homebrew refs.
- `scripts/generate_icon.swift` (~361L) — Programmatically renders the sculptural obsidian D monogram `AppIcon.icns`.
- `scripts/package_dmg.sh` (~139L) — Builds `dist/Donby-<ver>-macOS-<arch>.dmg`, `.app.zip`, `latest.json`, and `SHA256SUMS.txt`, and optionally syncs `/Applications/Donby.app/Contents` in-place (`SYNC_INSTALLED_APP=1`).
- `scripts/release_local.sh` (~138L) — Local-first release: packages artifacts, syncs `/Applications/Donby.app` in-place (disable via `--no-install`), pushes branch, creates/updates GitHub Release via `gh`, syncs tag.
- `.github/workflows/build-dmg.yml` — GitHub Actions CI triggered on tag push `v*` (skips if `[local-release]` workflow already published or builds DMG/ZIP in CI).

## 2. macOS CLT SDK & Swift 6.4 Build System Workaround (IMPORTANT)
- On macOS with CommandLineTools (`xcode-select -p` == `/Library/Developer/CommandLineTools`), the default SDK may reference `SwiftUIMacros` without `libSwiftUIMacros.dylib`, and Swift 6.4's default `swiftbuild` engine invalidates explicit SDK module caches on every run (~54s no-op).
- **Always use**: `./scripts/dev.sh build` / `./scripts/dev.sh test` (or pass `--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`). `build_app.sh` feature-detects `--build-system` automatically so older Swift CI runners remain compatible.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **Preserve `/Applications/Donby.app` Inode**: `build_app.sh` and `AppUpdateManager` replace `/Applications/Donby.app/Contents` in-place rather than `rm -rf /Applications/Donby.app` so macOS Dock does not lose the pinned app reference or spawn duplicate Dock icons (`v1.3.33`).
2. **No Stray `./Donby.app` in Workspace**: `build_app.sh` unregisters (`lsregister -u`) and removes `./Donby.app` to prevent LaunchServices duplicate bundle registration (`v1.3.17`).
3. **Version Bump & Mandatory Release Checklist**: Every code commit MUST bump `vX.Y.Z` atomically in all 3 version sources (`build_app.sh`, `Sources/DonbyCore/AppUpdatePolicies.swift` `DonbyAppInfo.fallbackVersion`, `docs/agent/INDEX.md`) and publish a GitHub Release via `./scripts/release_local.sh X.Y.Z` (defaults to `--prerelease`; pass `--stable` ONLY when user explicitly requests a Stable release).
4. **Release Channels (`Stable` vs `Pre-release`)**: `AppUpdateChannel` (`DonbyCore/AppUpdatePolicies.swift`) + `AppUpdateManager.updateChannel` let users switch between `正式版 (Stable)` (`/releases/latest` + `latest.json`) and `预览版 (Pre-release)` (`/releases?per_page=15` including pre-releases).
5. **Tiered Verification Rule**: Never run `./build_app.sh` or DMG packaging during intermediate edits; use L1 `swift build` / `cmake --build build_kernel` until milestone delivery or release.
