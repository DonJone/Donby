# Donby Agent Development Protocol

This repository is developed primarily by AI agents (Antigravity). Follow this protocol strictly to minimize token usage, redundant codebase exploration, and regression risk.

## 1. Mandatory Read-First Routing (Progressive Disclosure)
Before grepping or reading large source files (`dk_engine.cpp`, `TurboCacheAndDownloadEngine.swift`, `PlayerView.swift`, `AppState.swift`), ALWAYS:
1. Read [docs/agent/INDEX.md](docs/agent/INDEX.md) first (< 100 lines).
2. Load ONLY the 1-2 relevant module maps under `docs/agent/modules/`.
3. Check `docs/agent/decisions/` before changing streaming concurrency, caching, or kernel architecture.
4. For local test harness paths and real-server benchmark commands, check `docs/agent/local/` (git-ignored, local-only).

## 2. Mandatory Commit, Version & Documentation Sync Protocol
Every **code commit** MUST bind **Version Bump + Structured Commit + `docs/agent/` Sync** together as one atomic unit (pure `docs:`-only commits do not bump the version):
1. **Atomic Version Bump (`vX.Y.Z`)**:
   - Increment the patch version (e.g. `1.4.0 -> 1.4.1`, or minor on user request) across ALL 6 locations in the same commit:
     - `build_app.sh` (`APP_VERSION="${DONBY_VERSION:-X.Y.Z}"`)
     - `Sources/DonbyApp/PlayerView.swift` (fallback `appVer`)
     - `Sources/DonbyNetwork/AppUpdateManager.swift` (`currentVersion` fallback)
     - `Sources/DonbyNetwork/EmbyClient.swift` (`clientVersion` fallback)
     - `Sources/DonbyNetwork/UHDStreamClient.swift` (`clientVersion` fallback)
     - `docs/agent/INDEX.md` (`Current Version`)
2. **Structured Commit Message**:
   - Header: `<type>(<scope>): <concise summary> (vX.Y.Z)` (Conventional Commits; version suffix mandatory for code commits).
   - Body (recommended for non-trivial commits): `Why` / `What` / `Invariants` / `Verified`.
3. **Append to Active Changelog Shard**:
   - Add one structured entry at the top of the current version shard under `docs/agent/changelog/` (currently `docs/agent/changelog/v1.4.md`) keyed by **`vX.Y.Z`** (never `(next)` or bare `main`) following `docs/agent/changelog/TEMPLATE.md`.
   - Start a new shard when bumping a minor version (e.g., `v1.5.md`) or when a shard exceeds ~300 lines.
4. **Incremental Module Map Update**:
   - Update the affected `docs/agent/modules/*.md` (including its `Last synced: vX.Y.Z` header) ONLY when symbols, state machines, lock ordering, key thresholds, or invariants change. Do NOT rewrite untouched docs or copy full source code into docs.
5. **ADR Creation**:
   - Add a numbered file under `docs/agent/decisions/` when making a non-obvious architectural trade-off or rejecting an approach that failed in real testing (prevents future agents from retrying failed ideas).

## 3. Hard Redlines
- **Zero Secrets in Tracked Files**: Never write real server hostnames, URLs, API tokens, or user credentials into `AGENTS.md` or tracked files under `docs/agent/`. Keep environment-specific notes in `docs/agent/local/` (git-ignored).
- **Zero Emojis**: Do not use Unicode emojis in code, comments, commit messages, or docs.
- **Audio & Storage Isolation in Tests**: Always run CLI/automated playback tests with `DONBY_TEST_MUTED=1` and an isolated `DONBY_HOME=$(mktemp -d)` so user audio and production caches/settings are never touched.
- **macOS CLT SDK**: When `xcode-select -p` points to `/Library/Developer/CommandLineTools`, pass `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` to `swift build` / `swiftc` (or run `./build_app.sh` which auto-selects it).
- **Tiered Verification**:
  - L1 (quick edit): `swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` (and `cmake --build build_kernel` if C++ changed).
  - L2 (subsystem logic): run targeted regression / real-server harness with `DONBY_TEST_MUTED=1`.
  - L3 (release): `./build_app.sh` or `./scripts/release_local.sh` only when explicitly requested.
