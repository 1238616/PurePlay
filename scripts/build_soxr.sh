#!/usr/bin/env bash
# Build libsoxr.xcframework for macOS (arm64 + x86_64).
#
# SoXR is the SoX Resampler library — provides VHQ quality
# resampling that becomes the upgrade for our placeholder
# Kaiser-Sinc resampler.
#
# Output: Frameworks/libsoxr.xcframework
#
# Run:
#   ./scripts/build_soxr.sh [version]
# Default version: 0.1.3
#
# Integration after build:
#   .binaryTarget(name: "CSOXR", path: "Frameworks/libsoxr.xcframework")
#   PurePlayCore depends on CSOXR
#   import CSOXR in a Swift wrapper that replaces SincResampler
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.3}"
WORK="$ROOT/.build/soxr-build"
OUT="$ROOT/Frameworks/libsoxr.xcframework"

mkdir -p "$WORK"
cd "$WORK"

TARBALL="soxr-$VERSION-Source.tar.xz"
URL="https://sourceforge.net/projects/soxr/files/$TARBALL/download"
if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading SoXR $VERSION"
    curl -L -o "$TARBALL" "$URL"
fi

if [ ! -d "soxr-$VERSION-Source" ]; then
    echo "==> Extracting"
    tar -xf "$TARBALL"
fi

build_arch() {
    local ARCH="$1"
    local PREFIX="$WORK/install-$ARCH"
    if [ -f "$PREFIX/lib/libsoxr.a" ]; then
        echo "==> $ARCH already built, skipping"
        return
    fi
    local BUILD_DIR="$WORK/build-$ARCH"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    pushd "$BUILD_DIR" >/dev/null

    cmake "../soxr-$VERSION-Source" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DBUILD_TESTS=OFF \
        -DWITH_OPENMP=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        >/dev/null

    cmake --build . --config Release -- -j$(sysctl -n hw.ncpu) >/dev/null
    cmake --install . >/dev/null
    popd >/dev/null
}

build_arch arm64
build_arch x86_64

# -----------------------------------------------------------------
# Bundle xcframework
# -----------------------------------------------------------------
HEADERS_DIR="$WORK/install-arm64/include"
LIB_ARM64="$WORK/install-arm64/lib/libsoxr.a"
LIB_X86="$WORK/install-x86_64/lib/libsoxr.a"

[ -f "$LIB_ARM64" ] || { echo "Missing arm64 lib"; exit 1; }
[ -f "$LIB_X86" ]   || { echo "Missing x86_64 lib"; exit 1; }

# Module map
cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module CSOXR {
    header "soxr.h"
    link "soxr"
    export *
}
EOF

echo "==> Creating xcframework: $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$LIB_ARM64" -headers "$HEADERS_DIR" \
    -library "$LIB_X86"   -headers "$HEADERS_DIR" \
    -output "$OUT" >/dev/null

echo ""
echo "✓ Built $OUT"
echo "  Add to Package.swift:"
echo "    .binaryTarget(name: \"CSOXR\", path: \"Frameworks/libsoxr.xcframework\")"
