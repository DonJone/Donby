#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${DONBY_VERSION:-1.3.11}"
ARCH="$(uname -m)"
APP_NAME="Donby"
APP_DIR="${APP_NAME}.app"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}-macOS-${ARCH}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

echo "==> [1/4] Building standalone ${APP_DIR} (v${VERSION}, ${ARCH})..."
DONBY_VERSION="$VERSION" BUNDLE_DYLIBS=1 ./build_app.sh

echo "==> [2/4] Preparing DMG staging folder..."
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/donby-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_DIR" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

if [ -f "scripts/install_helper.command" ]; then
    cp "scripts/install_helper.command" "${STAGING_DIR}/一键安装或更新 (免安全验证).command"
    chmod +x "${STAGING_DIR}/一键安装或更新 (免安全验证).command"
fi

cat > "${STAGING_DIR}/安装说明.txt" << 'EOF'
Donby macOS 安装与更新指南
==============================================

【推荐方式】双击「一键安装或更新 (免安全验证).command」
  - 自动清理旧版残留与重名副本
  - 自动解除 Gatekeeper 隔离（免去“安全性与隐私”手动点击验证）
  - 自动刷新 macOS LaunchServices 注册表

【手动方式】将「Donby.app」拖入「Applications」
  - 若提示“无法打开，因为无法验证开发者”，在终端执行：
    xattr -dr com.apple.quarantine /Applications/Donby.app
  - 即可直接双击打开运行。
EOF

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${STAGING_DIR}/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$STAGING_DIR" || true
    elif [ -x "/usr/bin/SetFile" ]; then
        /usr/bin/SetFile -a C "$STAGING_DIR" || true
    fi
fi

echo "==> [3/4] Creating compressed UDZO disk image: ${DMG_PATH}..."
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Retry up to 3 times in case Spotlight/fsevents briefly holds the staging mount on CI runners
attempt=1
until hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"; do
    if [ "$attempt" -ge 3 ]; then
        echo "ERROR: hdiutil failed after ${attempt} attempts" >&2
        exit 1
    fi
    echo "Retrying hdiutil create (attempt $((attempt + 1))/3)..."
    attempt=$((attempt + 1))
    sleep 2
done

echo "==> [4/4] Verifying DMG & generating SHA256 checksum..."
hdiutil verify "$DMG_PATH" >/dev/null
(
    cd "$DIST_DIR"
    shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)

echo "==> Successfully packaged DMG:"
ls -lh "$DMG_PATH" "${DIST_DIR}/SHA256SUMS.txt"
cat "${DIST_DIR}/SHA256SUMS.txt"
