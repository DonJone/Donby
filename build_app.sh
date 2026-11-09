#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building native playback kernel..."
./build_kernel.sh

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [ ! -d "$SDK_PATH" ]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

echo "==> Building Donby release binary..."
swift build --sdk "$SDK_PATH" -c release

BIN_PATH="$(swift build --sdk "$SDK_PATH" -c release --show-bin-path)/Donby"
APP_DIR="Donby.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Donby"
chmod +x "$APP_DIR/Contents/MacOS/Donby"

echo "==> Generating native macOS AppIcon..."
swift -sdk "$SDK_PATH" scripts/generate_icon.swift
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

APP_VERSION="${DONBY_VERSION:-1.3.6}"

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
    <string>2</string>
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
echo "==> Packaged and signed: $(pwd)/$APP_DIR"
