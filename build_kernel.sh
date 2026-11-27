#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

HOST_ARCH="$(uname -m)"
TARGET_ARCH="${DONBY_ARCH:-$HOST_ARCH}"
PROFILE="${DONBY_RUST_PROFILE:-release}"
CARGO_ARGS=(--manifest-path KernelRust/Cargo.toml)
PROFILE_DIR="debug"
if [ "$PROFILE" = "release" ]; then
    CARGO_ARGS+=(--release)
    PROFILE_DIR="release"
fi

rust_target_for_arch() {
    case "$1" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64|x64) echo "x86_64-apple-darwin" ;;
        *)
            echo "ERROR: Unsupported target architecture: $1" >&2
            exit 1
            ;;
    esac
}

mkdir -p build_kernel
OUT_LIB="build_kernel/libdonby_kernel.a"

if [ "$TARGET_ARCH" = "universal" ]; then
    cargo build "${CARGO_ARGS[@]}" --target aarch64-apple-darwin
    cargo build "${CARGO_ARGS[@]}" --target x86_64-apple-darwin
    TMP_LIB="$(mktemp "${TMPDIR:-/tmp}/libdonby_kernel.XXXXXX.a")"
    trap 'rm -f "$TMP_LIB"' EXIT
    lipo -create \
        "KernelRust/target/aarch64-apple-darwin/${PROFILE_DIR}/libdonby_kernel_rs.a" \
        "KernelRust/target/x86_64-apple-darwin/${PROFILE_DIR}/libdonby_kernel_rs.a" \
        -output "$TMP_LIB"
    RUST_OUT="$TMP_LIB"
elif [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
    cargo build "${CARGO_ARGS[@]}"
    RUST_OUT="KernelRust/target/${PROFILE_DIR}/libdonby_kernel_rs.a"
else
    RUST_TARGET="$(rust_target_for_arch "$TARGET_ARCH")"
    cargo build "${CARGO_ARGS[@]}" --target "$RUST_TARGET"
    RUST_OUT="KernelRust/target/${RUST_TARGET}/${PROFILE_DIR}/libdonby_kernel_rs.a"
fi

if [ ! -f "$OUT_LIB" ] || ! cmp -s "$RUST_OUT" "$OUT_LIB"; then
    cp "$RUST_OUT" "$OUT_LIB"
fi
