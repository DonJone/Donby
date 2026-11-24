#!/usr/bin/env python3
"""Mechanical gate for Donby agent docs, 1:1 module-inventory coverage, and <=800L source ratchet."""
from __future__ import annotations

import argparse
import dataclasses
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_MAX_LINES = 800

LEGACY_LINE_CAPS: dict[str, int] = {}

@dataclasses.dataclass(frozen=True)
class DomainSpec:
    name: str
    leaf_docs: tuple[str, ...]
    index_doc: str | None
    prefixes: tuple[str, ...]
    extra_roots: tuple[str, ...] = ()
    check_index_inventory: bool = False

    @property
    def all_docs(self) -> tuple[str, ...]:
        return ((self.index_doc,) if self.index_doc else ()) + self.leaf_docs


DOMAINS: tuple[DomainSpec, ...] = (
    DomainSpec(
        name="kernel",
        index_doc="docs/agent/modules/kernel/INDEX.md",
        leaf_docs=(
            "docs/agent/modules/kernel/lifecycle-and-demux.md",
            "docs/agent/modules/kernel/video-and-audio.md",
            "docs/agent/modules/kernel/subtitles.md",
        ),
        prefixes=("KernelRust/src/", "Sources/DonbyKernelC/"),
        extra_roots=("KernelRust/src/",),
        check_index_inventory=True,
    ),
    DomainSpec(
        name="metal-renderer",
        index_doc=None,
        leaf_docs=("docs/agent/modules/metal-renderer.md",),
        prefixes=("Sources/DonbyMetalRenderer/",),
    ),
    DomainSpec(
        name="storage-core",
        index_doc=None,
        leaf_docs=("docs/agent/modules/storage-core.md",),
        prefixes=("Sources/DonbyCore/", "Tests/DonbyCoreTests/"),
    ),
    DomainSpec(
        name="turbo-network",
        index_doc=None,
        leaf_docs=("docs/agent/modules/turbo-network.md",),
        prefixes=("Sources/DonbyNetwork/",),
    ),
    DomainSpec(
        name="uhd-module",
        index_doc=None,
        leaf_docs=("docs/agent/modules/uhd-module.md",),
        prefixes=("Sources/DonbyUHDModule/", "Sources/DonbyApp/Modules/UHD/"),
    ),
    DomainSpec(
        name="player",
        index_doc="docs/agent/modules/player/INDEX.md",
        leaf_docs=(
            "docs/agent/modules/player/hud-and-drawers.md",
            "docs/agent/modules/player/playback-and-lifecycle.md",
            "docs/agent/modules/player/subtitles-and-tracks.md",
        ),
        prefixes=("Sources/DonbyApp/Player/",),
        check_index_inventory=True,
    ),
    DomainSpec(
        name="app",
        index_doc="docs/agent/modules/app/INDEX.md",
        leaf_docs=(
            "docs/agent/modules/app/state-and-shell.md",
            "docs/agent/modules/app/home-and-detail.md",
            "docs/agent/modules/app/native-collection-and-artwork.md",
            "docs/agent/modules/app/design-system.md",
            "docs/agent/modules/app/feature-views.md",
        ),
        prefixes=("Sources/DonbyApp/",),
    ),
    DomainSpec(
        name="build-release",
        index_doc=None,
        leaf_docs=("docs/agent/modules/build-release.md",),
        prefixes=("Package.swift", "build_app.sh", "build_kernel.sh", "scripts/", ".githooks/", ".github/workflows/"),
    ),
)

EMOJI_RE = re.compile(r"[\U0001F300-\U0001FAFF\U00002700-\U000027BF\U0001F1E6-\U0001F1FF\U00002600-\U000026FF]")
VOLATILE_LINE_COUNT_RE = re.compile(r"\(`?~?\d[\d,]*L`?(?:\s+range)?`?(?:,[^)]*)?\)")
VOLATILE_TEST_COUNT_RE = re.compile(r"\b\d+`?\s+`?@Test`?\s+cases\b")
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
SECTION1_RE = re.compile(r"^##\s+1\.\s+.*?(?=^##\s+2\.\s+|\Z)", re.MULTILINE | re.DOTALL)
SECTION2_RE = re.compile(r"^##\s+2\.\s+.*?(?=^##\s+3\.\s+|\Z)", re.MULTILINE | re.DOTALL)
LAST_SYNCED_RE = re.compile(r">\s*Last synced:\s*`v(\d+\.\d+\.\d+)`")
FILE_EXTS = (".swift", ".rs", ".c", ".h", ".sh", ".py", ".yml")


def run_git(root: Path, *args: str, check: bool = True) -> str:
    res = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout


def discover_owned_files(root: Path) -> dict[str, str]:
    owned: dict[str, str] = {}
    for base, exts in (("KernelRust/src", (".rs",)), ("Sources", (".swift", ".c", ".h")), ("Tests", (".swift",))):
        for p in sorted((root / base).rglob("*")):
            if p.is_file() and p.suffix in exts:
                rel = p.relative_to(root).as_posix()
                owned[rel] = classify_path(rel)
    for rel in (
        "Package.swift",
        "build_app.sh",
        "build_kernel.sh",
        *sorted(p.relative_to(root).as_posix() for p in (root / "scripts").glob("*") if p.is_file()),
        *sorted(p.relative_to(root).as_posix() for p in (root / ".githooks").glob("*") if p.is_file()),
        *sorted(p.relative_to(root).as_posix() for p in (root / ".github/workflows").glob("*.yml") if p.is_file()),
    ):
        if (root / rel).is_file():
            owned[rel] = "build-release"
    return owned


def classify_path(rel: str) -> str:
    if rel.startswith(("KernelRust/src/", "Sources/DonbyKernelC/")):
        return "kernel"
    if rel.startswith("Sources/DonbyMetalRenderer/"):
        return "metal-renderer"
    if rel.startswith(("Sources/DonbyCore/", "Tests/DonbyCoreTests/")):
        return "storage-core"
    if rel.startswith("Sources/DonbyNetwork/"):
        return "turbo-network"
    if rel.startswith(("Sources/DonbyUHDModule/", "Sources/DonbyApp/Modules/UHD/")):
        return "uhd-module"
    if rel.startswith("Sources/DonbyApp/Player/"):
        return "player"
    if rel.startswith("Sources/DonbyApp/"):
        return "app"
    return "build-release"


def resolve_inventory_token(token: str, domain: DomainSpec, all_owned: set[str]) -> list[str]:
    if any(ch in token for ch in ("*", "{", "}", "<", ">")) or token.endswith("/"):
        return []
    if token in all_owned:
        return [token]
    matches: list[str] = []
    for prefix in (*domain.prefixes, *domain.extra_roots):
        cand = f"{prefix}{token}"
        if cand in all_owned and cand not in matches:
            matches.append(cand)
    if not matches and "/" not in token:
        for rel in sorted(all_owned):
            if rel.endswith(f"/{token}") and classify_path(rel) == domain.name:
                matches.append(rel)
    return matches


def is_inventory_filename(tok: str) -> bool:
    return tok.endswith(FILE_EXTS) or tok == "Package.swift" or tok.startswith(".githooks/")


def extract_section_tokens(md_text: str, domain: DomainSpec, all_owned: set[str], section: int = 1) -> tuple[list[str], list[str]]:
    m = (SECTION1_RE if section == 1 else SECTION2_RE).search(md_text)
    if not m:
        return [], [f"Missing `## {section}.` section"]
    body = m.group(0)
    resolved: list[str] = []
    errors: list[str] = []
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("- "):
            header = re.split(r"\s+[—–-]{1,2}\s+|:\s+", s[2:], maxsplit=1)[0]
            for tok in BACKTICK_RE.findall(header):
                if not is_inventory_filename(tok):
                    continue
                hits = resolve_inventory_token(tok, domain, all_owned)
                if not hits:
                    errors.append(f"Unresolved inventory entry `{tok}` in {domain.name}")
                else:
                    resolved.extend(hits)
        elif s.startswith("|") and not s.startswith("| :---"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            for cell in cells[1:]:
                for tok in BACKTICK_RE.findall(cell):
                    if not is_inventory_filename(tok):
                        continue
                    hits = resolve_inventory_token(tok, domain, all_owned)
                    if not hits:
                        errors.append(f"Unresolved table entry `{tok}` in {domain.name}")
                    else:
                        resolved.extend(hits)
    return resolved, errors


def check_source_ratchet(root: Path, owned: dict[str, str]) -> list[str]:
    errs: list[str] = []
    seen_legacy: set[str] = set()
    for rel in sorted(owned):
        if not rel.endswith((".swift", ".rs", ".c", ".h")) and rel != "scripts/check_agent_docs.py":
            continue
        lines = len((root / rel).read_text(encoding="utf-8").splitlines())
        if rel in LEGACY_LINE_CAPS:
            seen_legacy.add(rel)
            cap = LEGACY_LINE_CAPS[rel]
            if lines <= DEFAULT_MAX_LINES:
                errs.append(f"Ratchet tighten: `{rel}` is now {lines}L <= {DEFAULT_MAX_LINES}L; remove it from LEGACY_LINE_CAPS in scripts/check_agent_docs.py")
            elif lines > cap:
                errs.append(f"Ratchet exceeded: `{rel}` is {lines}L > legacy cap {cap}L (shrink or split, never raise cap)")
        elif lines > DEFAULT_MAX_LINES:
            errs.append(f"Line limit exceeded: `{rel}` is {lines}L > {DEFAULT_MAX_LINES}L; split to <= {DEFAULT_MAX_LINES}L and update module docs")
    for missing in sorted(set(LEGACY_LINE_CAPS) - seen_legacy):
        errs.append(f"Stale LEGACY_LINE_CAPS entry `{missing}` no longer exists on disk; remove it from scripts/check_agent_docs.py")
    return errs


def check_bijection(root: Path, owned: dict[str, str]) -> list[str]:
    errs: list[str] = []
    all_owned = set(owned)
    file_to_docs: dict[str, list[str]] = {rel: [] for rel in all_owned}
    for domain in DOMAINS:
        for doc_rel in domain.leaf_docs:
            text = (root / doc_rel).read_text(encoding="utf-8")
            hits, tok_errs = extract_section_tokens(text, domain, all_owned, section=1)
            errs.extend(f"{doc_rel}: {e}" for e in tok_errs)
            for hit in dict.fromkeys(hits):
                if classify_path(hit) != domain.name:
                    errs.append(f"{doc_rel}: lists `{hit}` which belongs to domain `{classify_path(hit)}`")
                file_to_docs[hit].append(doc_rel)
        if domain.index_doc and domain.check_index_inventory:
            idx_text = (root / domain.index_doc).read_text(encoding="utf-8")
            idx_hits, idx_errs = extract_section_tokens(idx_text, domain, all_owned, section=2)
            errs.extend(f"{domain.index_doc}: {e}" for e in idx_errs)
            expected_dom = {r for r, d in owned.items() if d == domain.name}
            missing_idx = sorted(expected_dom - set(idx_hits))
            if missing_idx:
                errs.append(f"{domain.index_doc}: missing domain files in Section 2: {', '.join(missing_idx)}")
    for rel, docs in sorted(file_to_docs.items()):
        if not docs:
            errs.append(f"Orphan source file `{rel}` (domain `{owned[rel]}`) is not listed in any leaf module doc")
        elif len(docs) > 1:
            errs.append(f"Duplicate inventory entry `{rel}` listed in multiple docs: {', '.join(docs)}")
    return errs


def extract_versions(root: Path) -> tuple[dict[str, str], list[str]]:
    specs = (
        ("build_app.sh", r'^APP_VERSION="\$\{DONBY_VERSION:-(\d+\.\d+\.\d+)\}"$'),
        ("scripts/package_dmg.sh", r'^VERSION="\$\{DONBY_VERSION:-\$\{DEFAULT_VERSION:-(\d+\.\d+\.\d+)\}\}"$'),
        ("Sources/DonbyCore/AppUpdatePolicies.swift", r'public static let fallbackVersion = "(\d+\.\d+\.\d+)"'),
        ("Tests/DonbyCoreTests/DonbyCoreTests.swift", r'#expect\(DonbyAppInfo\.fallbackVersion == "(\d+\.\d+\.\d+)"\)'),
        ("docs/agent/INDEX.md", r'^- \*\*Current Version\*\*: `(\d+\.\d+\.\d+)`'),
    )
    found: dict[str, str] = {}
    errs: list[str] = []
    for rel, pat in specs:
        txt = (root / rel).read_text(encoding="utf-8")
        m = re.search(pat, txt, re.MULTILINE)
        if not m:
            errs.append(f"Version pattern not found in `{rel}`")
        else:
            found[rel] = m.group(1)
    if len(set(found.values())) > 1:
        errs.append(f"Version mismatch across 5 locations: {found}")
    return found, errs


def check_docs_hygiene(root: Path, version: str | None) -> list[str]:
    errs: list[str] = []
    idx_lines = len((root / "docs/agent/INDEX.md").read_text(encoding="utf-8").splitlines())
    if idx_lines >= 100:
        errs.append(f"docs/agent/INDEX.md must stay < 100 lines (currently {idx_lines}L)")
    md_files = [
        root / "AGENTS.md",
        root / "docs/agent/INDEX.md",
        *sorted((root / "docs/agent/decisions").glob("*.md")),
        *sorted((root / "docs/agent/modules").rglob("*.md")),
    ]
    for p in md_files:
        rel = p.relative_to(root).as_posix()
        txt = p.read_text(encoding="utf-8")
        for target in MD_LINK_RE.findall(txt):
            clean = target.split("#", 1)[0].strip()
            if not clean or clean.startswith(("http://", "https://", "mailto:")):
                continue
            if not (p.parent / clean).exists():
                errs.append(f"{rel}: broken markdown link `({target})`")
        if rel.startswith("docs/agent/modules/"):
            for i, line in enumerate(txt.splitlines(), 1):
                if VOLATILE_LINE_COUNT_RE.search(line):
                    errs.append(f"{rel}:{i}: volatile per-file line count tag forbidden (`{line.strip()[:80]}`)")
                if VOLATILE_TEST_COUNT_RE.search(line):
                    errs.append(f"{rel}:{i}: volatile `@Test` count forbidden (`{line.strip()[:80]}`)")
        if not rel.startswith("docs/agent/decisions/"):
            for tok in BACKTICK_RE.findall(txt):
                if "/" not in tok or any(ch in tok for ch in ("*", "{", "}", "<", ">", " ")) or tok.startswith(("/", "docs/agent/local/", "Application Support/", "Contents/", "build_kernel/", "dist/", "chunks/", "tmp/", "Modules/")):
                    continue
                if tok.endswith((".swift", ".rs", ".c", ".h", ".cpp", ".sh", ".py", ".yml", ".md")):
                    if not (root / tok).exists() and not (root / "Sources" / tok).exists() and not (root / "Sources/DonbyApp" / tok).exists() and not (root / "KernelRust/src" / tok).exists() and not (root / "Sources/DonbyUHDModule" / tok).exists() and not (root / "docs/agent" / tok).exists():
                        errs.append(f"{rel}: backticked path `{tok}` does not exist on disk")
    if version:
        major, minor, _ = version.split(".")
        shard = root / f"docs/agent/changelog/v{major}.{minor}.md"
        if not shard.exists():
            errs.append(f"Missing active changelog shard `{shard.relative_to(root).as_posix()}`")
        else:
            stxt = shard.read_text(encoding="utf-8")
            if len(stxt.splitlines()) > 350:
                errs.append(f"{shard.relative_to(root).as_posix()} exceeds 350L; rotate to a new shard")
            m = re.search(r"^##\s+v(\d+\.\d+\.\d+)\s+\|", stxt, re.MULTILINE)
            if not m or m.group(1) != version:
                errs.append(f"{shard.relative_to(root).as_posix()}: top changelog entry must be `## v{version} | ...`")
    return errs


def check_emojis(root: Path, extra_text: tuple[str, str] | None = None) -> list[str]:
    errs: list[str] = []
    files = run_git(root, "ls-files").splitlines() if (root / ".git").exists() else []
    for rel in files:
        if rel.endswith((".png", ".icns", ".safetensors")) or not (root / rel).is_file():
            continue
        try:
            txt = (root / rel).read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for i, line in enumerate(txt.splitlines(), 1):
            hits = [c for c in EMOJI_RE.findall(line) if c not in ("\u266a", "\u266b")]
            if hits and not (rel == "Sources/DonbyCore/ServerTextParser.swift" and "let pattern =" in line):
                errs.append(f"{rel}:{i}: forbidden Unicode emoji {hits}")
    if extra_text:
        label, txt = extra_text
        for i, line in enumerate(txt.splitlines(), 1):
            hits = [c for c in EMOJI_RE.findall(line) if c not in ("\u266a", "\u266b")]
            if hits:
                errs.append(f"{label}:{i}: forbidden Unicode emoji {hits}")
    return errs


def is_pure_version_bump(root: Path, rel: str) -> bool:
    pat_map = {
        "Sources/DonbyCore/AppUpdatePolicies.swift": "fallbackVersion",
        "Tests/DonbyCoreTests/DonbyCoreTests.swift": "DonbyAppInfo.fallbackVersion",
        "build_app.sh": "APP_VERSION=",
        "scripts/package_dmg.sh": "VERSION=",
    }
    needle = pat_map.get(rel)
    if not needle:
        return False
    diff = run_git(root, "diff", "--cached", "-U0", "--", rel)
    changed = [l[1:] for l in diff.splitlines() if (l.startswith("+") or l.startswith("-")) and not l.startswith(("+++", "---"))]
    return bool(changed) and all(needle in l for l in changed)


def has_structural_diff(root: Path, rel: str, status: str) -> bool:
    if status in ("A", "D", "R") or rel == "Sources/DonbyKernelC/include/donby_kernel.h":
        return True
    diff = run_git(root, "diff", "--cached", "-U0", "--", rel)
    for line in diff.splitlines():
        if not (line.startswith("+") or line.startswith("-")) or line.startswith(("+++", "---")):
            continue
        code = line[1:].strip()
        if rel.endswith(".swift") and re.match(r"^(?:public|internal|open|final\s+)*\b(class|struct|enum|actor|protocol)\s+\w+", code):
            if not re.match(r"^(private|fileprivate)\b", code):
                return True
        if rel.endswith(".rs") and ("#[no_mangle]" in code or re.search(r'\bextern\s+"C"\s+fn\s+dk_', code)):
            return True
    return False


def check_staged_and_commit(root: Path, owned: dict[str, str], version: str | None, commit_msg_file: Path | None) -> tuple[list[str], list[str]]:
    errs: list[str] = []
    infos: list[str] = []
    staged_lines = run_git(root, "diff", "--cached", "--name-status").splitlines()
    if not staged_lines:
        return ["No staged changes found"], infos
    staged_status: dict[str, str] = {}
    for row in staged_lines:
        parts = row.split("\t")
        st, path = parts[0][0], parts[-1]
        staged_status[path] = st
    unstaged = set(run_git(root, "diff", "--name-only").splitlines())
    both = sorted(unstaged & set(staged_status))
    if both:
        errs.append(f"Staged files have unstaged working-tree edits (stage or stash first): {', '.join(both)}")

    touched_domains: dict[str, list[tuple[str, str]]] = {}
    for rel, st in staged_status.items():
        if rel in owned and not is_pure_version_bump(root, rel):
            touched_domains.setdefault(owned[rel], []).append((rel, st))

    commit_txt = commit_msg_file.read_text(encoding="utf-8") if commit_msg_file else ""
    if commit_msg_file:
        errs.extend(check_emojis(root, ("commit-msg", commit_txt)))

    doc_sync_unchanged = bool(re.search(r"^Doc-Sync:\s*unchanged\s*\(.{8,}\)\s*$", commit_txt, re.MULTILINE))
    is_code_commit = any(
        p.startswith(("Sources/", "KernelRust/", "Tests/", "Resources/"))
        or p in ("Package.swift", "build_app.sh", "build_kernel.sh", "scripts/package_dmg.sh", "scripts/bundle_dylibs.py", "scripts/generate_icon.swift")
        for p in staged_status
    )

    for dom_name, items in sorted(touched_domains.items()):
        dom = next(d for d in DOMAINS if d.name == dom_name)
        staged_dom_docs = [d for d in dom.all_docs if d in staged_status]
        if staged_dom_docs and version and is_code_commit:
            for d in staged_dom_docs:
                m = LAST_SYNCED_RE.search((root / d).read_text(encoding="utf-8"))
                if m and m.group(1) != version:
                    errs.append(f"{d}: staged module doc has `Last synced: v{m.group(1)}`, expected `v{version}`")
        elif not staged_dom_docs:
            structural = [p for p, st in items if has_structural_diff(root, p, st)]
            if structural:
                errs.append(f"Domain `{dom_name}` has structural changes ({', '.join(structural)}) without staging any doc in {dom.all_docs}")
            elif commit_msg_file and not doc_sync_unchanged:
                errs.append(f"Domain `{dom_name}` edited without staging {dom.all_docs}; update the doc or add `Doc-Sync: unchanged (<reason>)` to commit body")
            elif not commit_msg_file:
                infos.append(f"[INFO] Domain `{dom_name}` edited without doc changes; commit body will require `Doc-Sync: unchanged (<reason>)` if doc remains accurate.")

    if commit_msg_file and version:
        header = commit_txt.splitlines()[0] if commit_txt.splitlines() else ""
        if is_code_commit:
            tag_check = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/v{version}"], cwd=root, capture_output=True)
            if tag_check.returncode == 0:
                errs.append(f"Code commit cannot reuse already-tagged version `v{version}`; bump all 5 version locations")
            m = re.match(r"^(feat|fix|refactor|perf|test|build|ci|chore)\([a-z0-9_,/-]+\): .+ \(v(\d+\.\d+\.\d+)\)( \[local-release\])?$", header)
            if not m or m.group(2) != version:
                errs.append(f"Code commit header must match `<type>(<scope>): <summary> (v{version}) [local-release]`")
        else:
            head_idx = run_git(root, "show", "HEAD:docs/agent/INDEX.md", check=False)
            hm = re.search(r"^- \*\*Current Version\*\*: `(\d+\.\d+\.\d+)`", head_idx, re.MULTILINE)
            if hm and hm.group(1) != version:
                errs.append(f"Docs-only commit must not bump version (`{hm.group(1)}` -> `{version}`)")
            if not re.match(r"^(docs|chore|ci)(\([a-z0-9_,/-]+\))?: .+", header):
                errs.append("Docs/governance commit header must start with `docs(...)`, `chore(...)`, or `ci(...)`")
    return errs, infos


def run_self_test() -> int:
    # 1. Volatile line count & test count regexes
    assert VOLATILE_LINE_COUNT_RE.search("- `Foo.swift` (`485L`) — bar")
    assert VOLATILE_LINE_COUNT_RE.search("- `Foo.swift` (`900L` range) — bar")
    assert not VOLATILE_LINE_COUNT_RE.search("Target Split: `<= 800L` per file")
    assert VOLATILE_TEST_COUNT_RE.search("Fast suite (`20` `@Test` cases)")
    # 2. Domain classification
    assert classify_path("Sources/DonbyApp/Player/PlayerView.swift") == "player"
    assert classify_path("Sources/DonbyApp/Modules/UHD/UHDModuleManager.swift") == "uhd-module"
    assert classify_path("Sources/DonbyApp/AppState.swift") == "app"
    assert classify_path("Sources/DonbyKernelC/dk_ffi_shim.c") == "kernel"
    # 3. Emoji detection & U+266A exemption
    assert EMOJI_RE.search("hello \U0001F680 world")
    assert [c for c in EMOJI_RE.findall("\u266a note") if c not in ("\u266a", "\u266b")] == []
    # 4. Ratchet invariants
    assert all(cap > DEFAULT_MAX_LINES for cap in LEGACY_LINE_CAPS.values())
    # 5. Resolve inventory tokens
    fake_owned = {"Sources/DonbyApp/Components/BrandMarks.swift", "KernelRust/src/subtitle/mod.rs"}
    app_dom = next(d for d in DOMAINS if d.name == "app")
    kern_dom = next(d for d in DOMAINS if d.name == "kernel")
    assert resolve_inventory_token("Components/BrandMarks.swift", app_dom, fake_owned) == ["Sources/DonbyApp/Components/BrandMarks.swift"]
    assert resolve_inventory_token("subtitle/mod.rs", kern_dom, fake_owned) == ["KernelRust/src/subtitle/mod.rs"]
    print("check_agent_docs.py --self-test: PASS (all assertions verified)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify Donby agent docs, 1:1 coverage, and <=800L source ratchet.")
    ap.add_argument("--staged", action="store_true", help="Also verify staged git changes & co-change rules")
    ap.add_argument("--commit-msg", type=Path, help="Verify commit message file + staged changes")
    ap.add_argument("--self-test", action="store_true", help="Run built-in unit self-tests")
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()

    root = Path(__file__).resolve().parent.parent
    owned = discover_owned_files(root)
    versions, errs = extract_versions(root)
    ver = next(iter(versions.values()), None) if len(set(versions.values())) == 1 else None
    errs.extend(check_source_ratchet(root, owned))
    errs.extend(check_bijection(root, owned))
    errs.extend(check_docs_hygiene(root, ver))
    errs.extend(check_emojis(root))

    infos: list[str] = []
    if args.staged or args.commit_msg:
        s_errs, s_infos = check_staged_and_commit(root, owned, ver, args.commit_msg)
        errs.extend(s_errs)
        infos.extend(s_infos)

    for info in infos:
        print(info)
    if errs:
        print(f"ERROR: check_agent_docs.py found {len(errs)} violation(s):", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"check_agent_docs.py: PASS ({len(owned)} owned files, 0 orphans, 0 broken links, v{ver or '?'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
