#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

FORCE_REBUILD=0
if [ "${1:-}" = "--force" ] || [ "${FORCE_KERNEL_REBUILD:-0}" = "1" ]; then
    FORCE_REBUILD=1
fi

OUT_LIB="build_kernel/libdonby_kernel.a"
if [ "$FORCE_REBUILD" != "1" ] && [ -f "$OUT_LIB" ] && \
   [ ! "Sources/DonbyKernelC/dk_engine.cpp" -nt "$OUT_LIB" ] && \
   [ ! "Sources/DonbyKernelC/include/donby_kernel.h" -nt "$OUT_LIB" ]; then
    echo "==> Up to date: $OUT_LIB (skipping C++ recompile; pass --force to rebuild)"
    exit 0
fi

echo "==> [1/2] Compiling DonbyKernelC (C++20 FFmpeg + VideoToolbox + libass)..."
mkdir -p build_kernel
clang++ -std=c++20 -O3 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -c Sources/DonbyKernelC/dk_engine.cpp \
  -I Sources/DonbyKernelC/include \
  -I "$BREW_PREFIX/include" \
  -I "$BREW_PREFIX/opt/ffmpeg/include" \
  -I "$BREW_PREFIX/opt/libass/include" \
  -o build_kernel/dk_engine.o

echo "==> [2/2] Creating static library libdonby_kernel.a..."
libtool -static -o build_kernel/libdonby_kernel.a \
  build_kernel/dk_engine.o

echo "==> Done! Output: build_kernel/libdonby_kernel.a"
