#!/usr/bin/env python3
"""
Recursively bundle non-system Homebrew dylibs (FFmpeg, libass, etc.) into
Donby.app/Contents/Frameworks and rewrite Mach-O install names to @rpath.
"""

from collections import deque
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/System/", "/usr/lib/")
FALLBACK_LIB_DIRS = ("/opt/homebrew/lib", "/usr/local/lib")


def run_cmd(cmd: list[str]) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return res.stdout


def is_system_lib(path: str) -> bool:
    return path.startswith(SYSTEM_PREFIXES)


def get_rpaths(binary_path: str) -> list[str]:
    out = run_cmd(["otool", "-l", binary_path])
    rpaths: list[str] = []
    lines = out.splitlines()
    for idx, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for sub in lines[idx + 1 : idx + 6]:
                sub = sub.strip()
                if sub.startswith("path "):
                    rpath = sub.split(" ", 1)[1].rsplit(" (offset", 1)[0].strip()
                    rpaths.append(rpath)
                    break
    return rpaths


def get_dependencies(binary_path: str, is_dylib: bool) -> list[str]:
    out = run_cmd(["otool", "-L", binary_path])
    lines = [ln.strip() for ln in out.splitlines()[1:] if ln.strip()]
    deps: list[str] = []
    for idx, line in enumerate(lines):
        raw = line.split(" (", 1)[0].strip()
        if is_dylib and idx == 0:
            # First entry of a dylib's otool -L output is LC_ID_DYLIB.
            continue
        deps.append(raw)
    return deps


def resolve_dep_path(raw_dep: str, loader_path: str, exec_dir: str, rpaths: list[str]) -> str:
    if raw_dep.startswith("/"):
        if os.path.exists(raw_dep):
            return os.path.realpath(raw_dep)
        raise FileNotFoundError(f"Missing absolute library dependency: {raw_dep}")

    loader_dir = os.path.dirname(loader_path)
    if raw_dep.startswith("@loader_path/"):
        cand = os.path.join(loader_dir, raw_dep[len("@loader_path/") :])
        if os.path.exists(cand):
            return os.path.realpath(cand)
    elif raw_dep.startswith("@executable_path/"):
        cand = os.path.join(exec_dir, raw_dep[len("@executable_path/") :])
        if os.path.exists(cand):
            return os.path.realpath(cand)
    elif raw_dep.startswith("@rpath/"):
        sub = raw_dep[len("@rpath/") :]
        search_dirs: list[str] = []
        for rp in rpaths:
            if rp.startswith("@loader_path"):
                rp = rp.replace("@loader_path", loader_dir, 1)
            elif rp.startswith("@executable_path"):
                rp = rp.replace("@executable_path", exec_dir, 1)
            search_dirs.append(rp)
        search_dirs.extend([loader_dir, *FALLBACK_LIB_DIRS])
        for d in search_dirs:
            cand = os.path.join(d, sub)
            if os.path.exists(cand):
                return os.path.realpath(cand)

    raise FileNotFoundError(f"Unable to resolve '{raw_dep}' referenced by {loader_path}")


def ensure_rpath(binary_path: str, target_rpath: str) -> None:
    existing = get_rpaths(binary_path)
    if target_rpath not in existing:
        subprocess.run(
            ["install_name_tool", "-add_rpath", target_rpath, binary_path],
            check=True,
        )


def bundle_app(app_path: str) -> None:
    app_path = os.path.abspath(app_path)
    exec_dir = os.path.join(app_path, "Contents", "MacOS")
    main_bin = os.path.join(exec_dir, "Donby")
    frameworks_dir = os.path.join(app_path, "Contents", "Frameworks")

    if not os.path.isfile(main_bin):
        raise FileNotFoundError(f"Executable not found: {main_bin}")

    os.makedirs(frameworks_dir, exist_ok=True)

    # real_source_path -> bundled filename inside Contents/Frameworks
    bundled_by_realpath: dict[str, str] = {}
    # source binary on disk -> original rpaths for resolution
    source_origin_for_bundled: dict[str, str] = {}

    queue: deque[tuple[str, str, bool]] = deque()
    # tuple: (target_binary_to_patch, origin_binary_for_resolving, is_dylib)
    queue.append((main_bin, main_bin, False))
    processed_targets: set[str] = set()

    while queue:
        target_bin, origin_bin, is_dylib = queue.popleft()
        if target_bin in processed_targets:
            continue
        processed_targets.add(target_bin)

        origin_rpaths = get_rpaths(origin_bin)
        deps = get_dependencies(target_bin, is_dylib=is_dylib)

        if is_dylib:
            dylib_name = os.path.basename(target_bin)
            subprocess.run(
                ["install_name_tool", "-id", f"@rpath/{dylib_name}", target_bin],
                check=True,
            )

        for raw_dep in deps:
            if is_system_lib(raw_dep):
                continue
            if raw_dep.startswith("@rpath/"):
                cand_in_fw = os.path.join(frameworks_dir, raw_dep[len("@rpath/") :])
                if os.path.exists(cand_in_fw):
                    continue

            real_src = resolve_dep_path(raw_dep, origin_bin, exec_dir, origin_rpaths)
            canonical_name = bundled_by_realpath.get(real_src)
            if canonical_name is None:
                canonical_name = os.path.basename(real_src)
                dest_path = os.path.join(frameworks_dir, canonical_name)
                if not os.path.exists(dest_path):
                    shutil.copy2(real_src, dest_path)
                    os.chmod(dest_path, 0o755)
                bundled_by_realpath[real_src] = canonical_name
                source_origin_for_bundled[dest_path] = real_src
                queue.append((dest_path, real_src, True))

            new_ref = f"@rpath/{canonical_name}"
            if raw_dep != new_ref:
                subprocess.run(
                    ["install_name_tool", "-change", raw_dep, new_ref, target_bin],
                    check=True,
                )

    ensure_rpath(main_bin, "@executable_path/../Frameworks")

    # Re-sign each bundled dylib individually before outer bundle signature
    bundled_files = sorted(
        os.path.join(frameworks_dir, f)
        for f in os.listdir(frameworks_dir)
        if f.endswith(".dylib")
    )
    for dylib in bundled_files:
        subprocess.run(["codesign", "--force", "--sign", "-", dylib], check=True)

    # Verify zero external Homebrew/local references remain
    leaked: list[str] = []
    for check_bin, is_dylib in [(main_bin, False)] + [(d, True) for d in bundled_files]:
        for dep in get_dependencies(check_bin, is_dylib=is_dylib):
            if not is_system_lib(dep) and not dep.startswith("@rpath/"):
                leaked.append(f"{os.path.basename(check_bin)} -> {dep}")
    if leaked:
        raise RuntimeError("Unbundled non-system dependencies remain:\n" + "\n".join(leaked))

    print(f"==> Bundled {len(bundled_files)} standalone dylibs into Contents/Frameworks")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/Donby.app", file=sys.stderr)
        sys.exit(1)
    bundle_app(sys.argv[1])
