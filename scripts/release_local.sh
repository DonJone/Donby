#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_VERSION="$(sed -n 's/^APP_VERSION="\${DONBY_VERSION:-\(.*\)}"$/\1/p' build_app.sh | head -n 1)"
ALLOW_DIRTY=0
CHANNEL="prerelease"
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --allow-dirty)
            ALLOW_DIRTY=1
            ;;
        --stable)
            CHANNEL="stable"
            ;;
        --prerelease)
            CHANNEL="prerelease"
            ;;
        -h|--help)
            echo "Usage: $0 [version] [--prerelease|--stable] [--allow-dirty]"
            echo "Builds Donby locally on macOS and publishes Release artifacts directly via gh CLI."
            echo "Default channel is --prerelease unless --stable is explicitly passed."
            exit 0
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                echo "ERROR: Unexpected argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

VERSION="${VERSION:-$DEFAULT_VERSION}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
    echo "ERROR: Unable to determine Donby version." >&2
    exit 1
fi

TAG="v${VERSION}"
ARCH="$(uname -m)"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/Donby-${VERSION}-macOS-${ARCH}.dmg"
ZIP_PATH="${DIST_DIR}/Donby-${VERSION}-macOS-${ARCH}.app.zip"
MANIFEST_PATH="${DIST_DIR}/latest.json"
SUMS_PATH="${DIST_DIR}/SHA256SUMS.txt"

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI (gh) is required." >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 1
fi

if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: Working tree has uncommitted changes. Commit first or pass --allow-dirty." >&2
    git status --short >&2
    exit 1
fi

echo "==> [1/4] Packaging local macOS build (${TAG}, ${ARCH})..."
DONBY_VERSION="$VERSION" ./scripts/package_dmg.sh

for f in "$DMG_PATH" "$ZIP_PATH" "$MANIFEST_PATH" "$SUMS_PATH"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing expected artifact: $f" >&2
        exit 1
    fi
done

TARGET_SHA="$(git rev-parse HEAD)"
BRANCH="$(git branch --show-current || true)"
if [ -n "$BRANCH" ]; then
    echo "==> [2/4] Pushing branch ${BRANCH} (${TARGET_SHA:0:7}) to origin..."
    git push origin "HEAD:${BRANCH}"
fi

NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/donby-release-notes.XXXXXX")"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<'MD'
### 安装说明 (macOS Apple Silicon)
1. 下载下方 `Donby-*.dmg` 并双击挂载，将 `Donby.app` 拖入 `Applications`（应用程序），或直接通过应用内“关于 -> 检查更新”一键升级。
2. 安装包已内嵌全部 `FFmpeg` / `libass` 运行库，无需额外部署 Homebrew 环境。
3. 由于开源构建采用本地 Ad-hoc 签名（未接入付费 Apple Developer 公证），首次打开如提示“无法验证开发者”或“已损坏”，请在终端执行一次：
   ```bash
   sudo xattr -rd com.apple.quarantine /Applications/Donby.app
   ```
MD

echo "==> [3/4] Publishing GitHub Release ${TAG} (channel=${CHANNEL}) directly from local artifacts..."
if [ "$CHANNEL" = "stable" ]; then
    CHANNEL_FLAGS=(--latest --prerelease=false)
else
    CHANNEL_FLAGS=(--prerelease --latest=false)
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG_PATH" "$ZIP_PATH" "$MANIFEST_PATH" "$SUMS_PATH" --clobber
    gh release edit "$TAG" "${CHANNEL_FLAGS[@]}" --notes-file "$NOTES_FILE"
else
    RELEASE_NOTES="$(cat "$NOTES_FILE")"
    if [ "$CHANNEL" = "stable" ]; then
        gh release create "$TAG" \
            "$DMG_PATH" "$ZIP_PATH" "$MANIFEST_PATH" "$SUMS_PATH" \
            --target "$TARGET_SHA" \
            --title "$TAG" \
            --generate-notes \
            --notes "$RELEASE_NOTES" \
            --latest
    else
        gh release create "$TAG" \
            "$DMG_PATH" "$ZIP_PATH" "$MANIFEST_PATH" "$SUMS_PATH" \
            --target "$TARGET_SHA" \
            --title "${TAG} (Pre-release)" \
            --generate-notes \
            --notes "$RELEASE_NOTES" \
            --prerelease
    fi
fi

echo "==> [4/4] Syncing tag ${TAG} locally..."
git fetch origin "refs/tags/${TAG}:refs/tags/${TAG}" --force

echo "==> Release ${TAG} published successfully (local build, zero CI queue):"
gh release view "$TAG" --json url,tagName,assets --jq '{url, tagName, assets: [.assets[].name]}'
