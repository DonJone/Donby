#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

resolve_sdk() {
    local dev_dir="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "${DONBY_SDK_PATH:-}" ] && [ -d "${DONBY_SDK_PATH}" ]; then
        echo "${DONBY_SDK_PATH}"
        return
    fi
    local sdk="$(xcrun --show-sdk-path)"
    if [ "$dev_dir" = "/Library/Developer/CommandLineTools" ]; then
        local clt_plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"
        local fallback="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
        if [ ! -f "${clt_plugins}/libSwiftUIMacros.dylib" ] && \
           grep -q "SwiftUIMacros" "${sdk}/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/"*.swiftinterface 2>/dev/null && \
           [ -d "$fallback" ]; then
            echo "$fallback"
            return
        fi
    fi
    echo "$sdk"
}

SDK_PATH="$(resolve_sdk)"
BUILD_SYS_ARGS=()
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
    BUILD_SYS_ARGS=(--build-system "${DONBY_BUILD_SYSTEM:-native}")
fi

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
COMMON_FW_ARGS=()
if [ -d "${CLT_FW}/Testing.framework" ]; then
    COMMON_FW_ARGS=(
        -Xswiftc -F -Xswiftc "$CLT_FW"
        -Xlinker -F -Xlinker "$CLT_FW"
        -Xlinker -rpath -Xlinker "$CLT_FW"
    )
fi

CMD="${1:-build}"
shift || true

case "$CMD" in
    build)
        ./build_kernel.sh
        exec swift build "${BUILD_SYS_ARGS[@]}" --sdk "$SDK_PATH" "${COMMON_FW_ARGS[@]}" "$@"
        ;;
    test)
        ./build_kernel.sh
        cargo test --manifest-path KernelRust/Cargo.toml
        TMPHOME="$(mktemp -d)"
        trap 'rm -rf "$TMPHOME"' EXIT
        DONBY_HOME="$TMPHOME" swift test "${BUILD_SYS_ARGS[@]}" --sdk "$SDK_PATH" "${COMMON_FW_ARGS[@]}" --disable-xctest "$@"
        ;;
    app)
        exec ./build_app.sh "$@"
        ;;
    release)
        exec ./scripts/release_local.sh "$@"
        ;;
    *)
        echo "Usage: $0 [build|test|app|release] [extra args...]" >&2
        exit 1
        ;;
esac
