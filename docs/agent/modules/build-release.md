# Module Map: Build, Packaging & Release Pipeline

> Last synced: `v1.4.0` (`f35082e`). Load this doc for compiling Swift/C++/Rust, bundling dylibs, signing `/Applications/Donby.app`, DMG/ZIP packaging, local-first GitHub Releases, and CI.

## 1. File Inventory
- `Package.swift` — SwiftPM manifest linking `DonbyKernelC` (`build_kernel/libdonby_kernel.a`) and `KernelRust` (`KernelRust/target/release/libdonby_rs.a`).
- `CMakeLists.txt` + `build_kernel.sh` — Builds Rust release static lib + CMake C++20 `DonbyKernelC` static lib in `build_kernel/`.
- `build_app.sh` (~131L) — Full local release build: runs `build_kernel.sh`, selects valid macOS SDK, builds `swift build -c release`, updates `/Applications/Donby.app/Contents/` **in-place**, generates `AppIcon.icns`, bundles FFmpeg/libass dylibs via `scripts/bundle_dylibs.py`, ad-hoc codesigns (`codesign --force --deep --sign -`).
- `scripts/bundle_dylibs.py` (~187L) — Copies Homebrew FFmpeg/libass transitive dylibs into `Contents/Frameworks/` and rewrites `@rpath` / `install_name` so the app is self-contained.
- `scripts/generate_icon.swift` (~361L) — Programmatically renders the sculptural obsidian D monogram `AppIcon.icns`.
- `scripts/package_dmg.sh` (~129L) — Builds `dist/Donby-<ver>-macOS-<arch>.dmg`, `.app.zip`, `latest.json`, and `SHA256SUMS.txt`.
- `scripts/release_local.sh` (~110L) — Local-first release: packages artifacts, pushes branch, creates/updates GitHub Release via `gh`, syncs tag (zero CI wait).
- `.github/workflows/build-dmg.yml` — GitHub Actions CI triggered on tag push `v*` (skips if `[local-release]` workflow already published or builds DMG/ZIP in CI).

## 2. macOS CLT SDK Workaround (IMPORTANT)
- On macOS with CommandLineTools (`xcode-select -p` == `/Library/Developer/CommandLineTools`), the default SDK may reference `SwiftUIMacros` without `libSwiftUIMacros.dylib`.
- **Always pass**: `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` to `swift build` / `swiftc` (or set `DONBY_SDK_PATH`). `build_app.sh` handles this automatically.

## 3. Critical Invariants & Pitfalls (DO NOT BREAK)
1. **Preserve `/Applications/Donby.app` Inode**: `build_app.sh` and `AppUpdateManager` replace `/Applications/Donby.app/Contents` in-place rather than `rm -rf /Applications/Donby.app` so macOS Dock does not lose the pinned app reference or spawn duplicate Dock icons (`v1.3.33`).
2. **No Stray `./Donby.app` in Workspace**: `build_app.sh` unregisters (`lsregister -u`) and removes `./Donby.app` to prevent LaunchServices duplicate bundle registration (`v1.3.17`).
3. **Version Bump Checklist (Mandatory on Every Code Commit)**: Always bump `vX.Y.Z` atomically in all 6 locations: `build_app.sh` (`DONBY_VERSION`), `Sources/DonbyApp/PlayerView.swift`, `Sources/DonbyNetwork/AppUpdateManager.swift`, `Sources/DonbyNetwork/EmbyClient.swift`, `Sources/DonbyNetwork/UHDStreamClient.swift`, and `docs/agent/INDEX.md`.
4. **Tiered Verification Rule**: Never run `./build_app.sh` or DMG packaging during intermediate edits; use L1 `swift build` / `cmake --build build_kernel` until milestone delivery.
