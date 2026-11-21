# Donby Agent Development Protocol

This repository is developed primarily by AI agents (Antigravity). Follow this protocol strictly to minimize token usage, redundant codebase exploration, and regression risk.

## 1. Mandatory Read-First Routing (Progressive Disclosure)
Before grepping or reading large source files (`dk_engine.cpp`, `TurboCacheAndDownloadEngine.swift`, `PlayerView.swift`, `AppState.swift`), ALWAYS:
1. Read [docs/agent/INDEX.md](docs/agent/INDEX.md) first (< 100 lines).
2. Load ONLY the 1-2 relevant module maps under `docs/agent/modules/`.
3. Check `docs/agent/decisions/` before changing streaming concurrency, caching, or kernel architecture.
4. For local test harness paths and real-server benchmark commands, check `docs/agent/local/` (git-ignored, local-only).

## 2. Mandatory Commit, Version, Release & Documentation Sync Protocol
Every **code commit** MUST bind **Version Bump + Structured Commit + `docs/agent/` Sync + GitHub Release** together (pure `docs:`-only commits do not bump the version or publish a release):
1. **Atomic Version Bump (`vX.Y.Z`)**:
   - Increment the patch version (e.g. `1.4.11 -> 1.4.12`, or minor on user request) across ALL 3 version sources in the same commit:
     - `build_app.sh` (`APP_VERSION="${DONBY_VERSION:-X.Y.Z}"`)
     - `Sources/DonbyCore/AppUpdatePolicies.swift` (`DonbyAppInfo.fallbackVersion`)
     - `docs/agent/INDEX.md` (`Current Version`)
     *(All Swift modules read `DonbyAppInfo.version`; `scripts/package_dmg.sh` and CI read `build_app.sh`.)*
2. **Structured Commit Message**:
   - Header: `<type>(<scope>): <concise summary> (vX.Y.Z) [local-release]` (Conventional Commits; version suffix mandatory for code commits; append `[local-release]` when publishing locally via `scripts/release_local.sh` to skip redundant cloud CI).
   - Body (recommended for non-trivial commits): `Why` / `What` / `Invariants` / `Verified`.
3. **Mandatory GitHub Release on Every Version Bump (Channel-Aware)**:
   - Every time the version number `vX.Y.Z` changes, publish a GitHub Release via `./scripts/release_local.sh X.Y.Z [--prerelease|--stable]`.
   - **Default Channel = `pre-release` (`--prerelease`)**: Unless the user explicitly requests a Stable / formal release (`--stable`), ALWAYS publish to the **`pre-release`** channel (`--prerelease`). Stable releases require explicit user confirmation and pass `--stable` (which sets GitHub `--latest`).
4. **Append to Active Changelog Shard**:
   - Add one structured entry at the top of the current version shard under `docs/agent/changelog/` (currently `docs/agent/changelog/v1.4.md`) keyed by **`vX.Y.Z`** (never `(next)` or bare `main`) following `docs/agent/changelog/TEMPLATE.md`, including release channel (`Pre-release` or `Stable`).
   - Start a new shard when bumping a minor version (e.g., `v1.5.md`) or when a shard exceeds ~300 lines.
5. **Incremental Module Map Update**:
   - Update the affected `docs/agent/modules/*.md` (including its `Last synced: vX.Y.Z` header) ONLY when symbols, state machines, lock ordering, key thresholds, or invariants change. Do NOT rewrite untouched docs or copy full source code into docs.
6. **ADR Creation**:
   - Add a numbered file under `docs/agent/decisions/` when making a non-obvious architectural trade-off or rejecting an approach that failed in real testing (prevents future agents from retrying failed ideas).

## 3. Hard Redlines
- **Zero Secrets in Tracked Files**: Never write real server hostnames, URLs, API tokens, or user credentials into `AGENTS.md` or tracked files under `docs/agent/`. Keep environment-specific notes in `docs/agent/local/` (git-ignored).
- **Zero Emojis**: Do not use Unicode emojis in code, comments, commit messages, or docs.
- **Audio & Storage Isolation in Tests**: Always run CLI/automated playback tests with `DONBY_TEST_MUTED=1` and an isolated `DONBY_HOME=$(mktemp -d)` so user audio and production caches/settings are never touched.
- **macOS CLT SDK & Fast Build**: Use `./scripts/dev.sh build` / `./scripts/dev.sh test` (or pass `--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` to `swift build`) to avoid Swift 6.4 `swiftbuild` explicit-module cache invalidation on CLT. SwiftPM compiles `DonbyKernelC/dk_engine.cpp` once directly at `-O3`.
- **Tiered Verification**:
  - L1 (quick edit): `./scripts/dev.sh build` (~1.3s incremental).
  - L2 (subsystem logic): `./scripts/dev.sh test` (~0.9s isolated `DonbyCoreTests`) or targeted real-server harness with `DONBY_TEST_MUTED=1`.
  - L3 (release): `./build_app.sh` or `./scripts/release_local.sh` only when explicitly requested (`release_local.sh` auto-syncs `/Applications/Donby.app` in-place).
