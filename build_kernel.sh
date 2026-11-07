#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "==> [1/3] Building KernelRust (Rust memory arena + DoVi parser)..."
cd KernelRust
cargo build --release
cd ..

echo "==> [2/3] Compiling DonbyKernelC (C++20 FFmpeg + VideoToolbox + libass)..."
mkdir -p build_kernel
clang++ -std=c++20 -O3 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -c Sources/DonbyKernelC/dk_engine.cpp \
  -I Sources/DonbyKernelC/include \
  -I KernelRust/include \
  -I "$BREW_PREFIX/include" \
  -I "$BREW_PREFIX/opt/ffmpeg/include" \
  -I "$BREW_PREFIX/opt/libass/include" \
  -o build_kernel/dk_engine.o

echo "==> [3/3] Creating static library libdonby_kernel.a..."
libtool -static -o build_kernel/libdonby_kernel.a \
  build_kernel/dk_engine.o \
  KernelRust/target/release/libdonby_rs.a

echo "==> Done! Output: build_kernel/libdonby_kernel.a"
