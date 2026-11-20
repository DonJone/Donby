#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${DONBY_VERSION:-1.3.31}"
ARCH="$(uname -m)"
APP_NAME="Donby"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}-macOS-${ARCH}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
ZIP_NAME="${APP_NAME}-${VERSION}-macOS-${ARCH}.app.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/donby-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

if [ -n "${CI:-}" ]; then
    APP_DIR="${APP_NAME}.app"
else
    APP_DIR="${STAGING_DIR}/${APP_NAME}.app"
fi

echo "==> [1/4] Building standalone ${APP_DIR} (v${VERSION}, ${ARCH})..."
DONBY_VERSION="$VERSION" DONBY_APP_DIR="$APP_DIR" BUNDLE_DYLIBS=1 ./build_app.sh

echo "==> [1.5/4] Verifying standalone dylib closure & signature..."
codesign --verify --deep --strict "$APP_DIR"
if otool -L "${APP_DIR}/Contents/MacOS/Donby" "${APP_DIR}/Contents/Frameworks/"*.dylib | grep -E "(/opt/homebrew|/usr/local)"; then
    echo "ERROR: Found unbundled external Homebrew dylib paths!" >&2
    exit 1
fi

echo "==> [2/4] Preparing .app.zip & DMG staging folder..."
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
unzip -tq "$ZIP_PATH" >/dev/null

if [ "$APP_DIR" != "${STAGING_DIR}/${APP_NAME}.app" ]; then
    cp -R "$APP_DIR" "${STAGING_DIR}/${APP_NAME}.app"
fi
ln -s /Applications "${STAGING_DIR}/Applications"
touch "${STAGING_DIR}/.metadata_never_index"

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

echo "==> [4/4] Verifying DMG & generating SHA256/latest.json..."
sync
sleep 2
verify_attempt=1
until hdiutil verify "$DMG_PATH" >/dev/null; do
    if [ "$verify_attempt" -ge 5 ]; then
        echo "ERROR: hdiutil verify failed after ${verify_attempt} attempts" >&2
        exit 1
    fi
    echo "Retrying hdiutil verify (attempt $((verify_attempt + 1))/5)..."
    verify_attempt=$((verify_attempt + 1))
    sleep 3
done
(
    cd "$DIST_DIR"
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)

python3 - "$VERSION" "$ARCH" "$DMG_PATH" "$ZIP_PATH" "$DIST_DIR/latest.json" <<'PY'
import hashlib, json, os, sys
from datetime import datetime, timezone

version, arch, dmg_path, zip_path, out_path = sys.argv[1:6]

def file_info(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while chunk := f.read(262144):
            h.update(chunk)
    return h.hexdigest(), os.path.getsize(p)

dmg_sha, dmg_size = file_info(dmg_path)
zip_sha, zip_size = file_info(zip_path)
manifest = {
    "version": version,
    "tag_name": f"v{version}",
    "published_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "arch": arch,
    "dmg_name": os.path.basename(dmg_path),
    "dmg_sha256": dmg_sha,
    "dmg_size": dmg_size,
    "zip_name": os.path.basename(zip_path),
    "zip_sha256": zip_sha,
    "zip_size": zip_size,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "==> Successfully packaged DMG & .app.zip:"
ls -lh "$DMG_PATH" "$ZIP_PATH" "${DIST_DIR}/SHA256SUMS.txt" "${DIST_DIR}/latest.json"
cat "${DIST_DIR}/SHA256SUMS.txt"
