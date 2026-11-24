#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

PROFILE="${DONBY_RUST_PROFILE:-release}"
CARGO_ARGS=(--manifest-path KernelRust/Cargo.toml)
if [ "$PROFILE" = "release" ]; then
    CARGO_ARGS+=(--release)
    RUST_OUT="KernelRust/target/release/libdonby_kernel_rs.a"
else
    RUST_OUT="KernelRust/target/debug/libdonby_kernel_rs.a"
fi

cargo build "${CARGO_ARGS[@]}"

mkdir -p build_kernel
OUT_LIB="build_kernel/libdonby_kernel.a"
if [ ! -f "$OUT_LIB" ] || ! cmp -s "$RUST_OUT" "$OUT_LIB"; then
    cp "$RUST_OUT" "$OUT_LIB"
fi
