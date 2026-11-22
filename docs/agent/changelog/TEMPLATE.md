# Changelog Entry Template

Every **code commit** MUST bump `vX.Y.Z` across all 5 version locations (`build_app.sh`, `scripts/package_dmg.sh`, `Sources/DonbyCore/AppUpdatePolicies.swift`, `Tests/DonbyCoreTests/DonbyCoreTests.swift`, `docs/agent/INDEX.md` — see `AGENTS.md` Section 2) and prepend one entry to the **top** of the active version shard (`docs/agent/changelog/vX.Y.md`) keyed by that exact version `vX.Y.Z`.
Pure `docs:`-only commits do not bump the version or publish a release. Keep entries dense, factual, and free of raw source dumps or sensitive URLs/tokens.

```markdown
## vX.Y.Z | <YYYY-MM-DD> | <Pre-release|Stable> | <short title>
- **Scope**: `<module1>, <module2>`
- **Root Cause / Goal**: One or two crisp sentences explaining the bug or objective.
- **Changes**:
  - `path/to/File.swift` (`SymbolName`): What changed and why (include key constants/thresholds).
  - `path/to/File.cpp` (`dk_func_name`): What changed and why.
- **Invariants & Pitfalls**: Constraints future agents MUST NOT break.
- **Verification**: Exact test suites / benchmarks run and key numeric results.
```

## Git Commit Message Format (Mandatory for Code Commits)
```text
<type>(<scope>): <concise summary> (vX.Y.Z) [local-release]

Why: <root cause or user goal>
What: <bulleted key file/symbol changes>
Invariants: <critical constraints preserved>
Verified: <L1/L2/L3 test summary>
```
