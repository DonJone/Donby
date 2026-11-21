#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building native playback kernel..."
./build_kernel.sh

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -n "${DONBY_SDK_PATH:-}" ] && [ -d "${DONBY_SDK_PATH}" ]; then
    SDK_PATH="${DONBY_SDK_PATH}"
elif [ "$DEV_DIR" = "/Library/Developer/CommandLineTools" ]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
    CLT_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"
    FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [ ! -f "${CLT_PLUGINS}/libSwiftUIMacros.dylib" ] && \
       grep -q "SwiftUIMacros" "${SDK_PATH}/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/"*.swiftinterface 2>/dev/null && \
       [ -d "$FALLBACK_SDK" ]; then
        echo "==> Note: CLT SDK $(basename "$SDK_PATH") requires SwiftUIMacros (Xcode plugin); using $(basename "$FALLBACK_SDK")"
        SDK_PATH="$FALLBACK_SDK"
    fi
else
    SDK_PATH="$(xcrun --show-sdk-path)"
fi
if [ ! -d "$SDK_PATH" ]; then
    echo "ERROR: Valid macOS SDK not found: $SDK_PATH" >&2
    exit 1
fi

echo "==> Building Donby release binary..."
swift build --sdk "$SDK_PATH" -c release

BIN_PATH="$(swift build --sdk "$SDK_PATH" -c release --show-bin-path)/Donby"
APP_DIR="${DONBY_APP_DIR:-/Applications/Donby.app}"

# Always remove any stray workspace ./Donby.app so LaunchServices & Dock never see two Donby.app bundles
if [ "$APP_DIR" != "Donby.app" ] && [ "$APP_DIR" != "$(pwd)/Donby.app" ] && [ -e "Donby.app" ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$(pwd)/Donby.app" >/dev/null 2>&1 || true
    fi
    rm -rf "Donby.app"
fi

# Update Contents/ in-place to preserve top-level /Applications/Donby.app directory inode for macOS Dock
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Contents"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Donby"
chmod +x "$APP_DIR/Contents/MacOS/Donby"

echo "==> Generating native macOS AppIcon..."
swift -sdk "$SDK_PATH" scripts/generate_icon.swift
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp Resources/uhdnow_*.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true

APP_VERSION="${DONBY_VERSION:-1.4.11}"
BUILD_NUMBER="${DONBY_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Donby</string>
    <key>CFBundleExecutable</key>
    <string>Donby</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.don.Donby</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Donby</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>com.don.Donby.scheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>donby</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

if [ "${BUNDLE_DYLIBS:-1}" = "1" ]; then
    echo "==> Bundling standalone FFmpeg & libass dylibs..."
    python3 scripts/bundle_dylibs.py "$APP_DIR"
fi

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ABS_APP_DIR="$(cd "$(dirname "$APP_DIR")" && pwd)/$(basename "$APP_DIR")"
if [ -z "${CI:-}" ] && [ "$ABS_APP_DIR" != "/Applications/Donby.app" ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$ABS_APP_DIR" >/dev/null 2>&1 || true
    fi
fi
echo "==> Packaged and signed: ${ABS_APP_DIR}"
