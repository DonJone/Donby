# Changelog Entry Template

Append new entries to the **top** of the active version shard (`docs/agent/changelog/vX.Y.md`).
Keep entries dense, factual, and free of raw source dumps or sensitive URLs/tokens.

```markdown
## <hash> | <YYYY-MM-DD> | <tag or branch> | <short title>
- **Scope**: `<module1>, <module2>`
- **Root Cause / Goal**: One or two crisp sentences explaining the bug or objective.
- **Changes**:
  - `path/to/File.swift` (`SymbolName`): What changed and why (include key constants/thresholds).
  - `path/to/File.cpp` (`dk_func_name`): What changed and why.
- **Invariants & Pitfalls**: Constraints future agents MUST NOT break.
- **Verification**: Exact test suites / benchmarks run and key numeric results.
```

## Git Commit Message Format (Recommended)
```text
<type>(<scope>): <concise summary> (vX.Y.Z)

Why: <root cause or user goal>
What: <bulleted key file/symbol changes>
Invariants: <critical constraints preserved>
Verified: <L1/L2/L3 test summary>
```
