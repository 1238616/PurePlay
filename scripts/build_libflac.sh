#!/usr/bin/env bash
# Build libFLAC.xcframework for macOS (arm64 + x86_64).
#
# Output: Frameworks/libFLAC.xcframework
# Includes static libraries + module map so SwiftPM systemLibrary or binaryTarget
# can consume it.
#
# Prerequisites:
#   - Xcode command line tools (clang, lipo)
#   - autoconf, automake, libtool, pkg-config  (brew install)
#   - curl + tar
#
# Run:
#   ./scripts/build_libflac.sh [version]
# Default version: 1.4.3
#
# After successful build, declare the dependency in Package.swift:
#
#   .binaryTarget(
#     name: "CFLAC",
#     path: "Frameworks/libFLAC.xcframework"
#   )
#
# Then add CFLAC to the PurePlayCore target's dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.4.3}"
WORK="$ROOT/.build/libflac-build"
OUT="$ROOT/Frameworks/libFLAC.xcframework"

mkdir -p "$WORK"
cd "$WORK"

TARBALL="flac-$VERSION.tar.xz"
URL="https://downloads.xiph.org/releases/flac/$TARBALL"
if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading $URL"
    curl -L -o "$TARBALL" "$URL"
fi

if [ ! -d "flac-$VERSION" ]; then
    echo "==> Extracting"
    tar -xf "$TARBALL"
fi

build_arch() {
    local ARCH="$1"
    local PREFIX="$WORK/install-$ARCH"
    if [ -f "$PREFIX/lib/libFLAC.a" ]; then
        echo "==> $ARCH already built, skipping"
        return
    fi

    pushd "flac-$VERSION" >/dev/null
    make distclean 2>/dev/null || true

    local HOST=""
    local CFLAGS_EXTRA=""
    case "$ARCH" in
        arm64)  HOST="aarch64-apple-darwin"; CFLAGS_EXTRA="-arch arm64" ;;
        x86_64) HOST="x86_64-apple-darwin";  CFLAGS_EXTRA="-arch x86_64" ;;
    esac

    echo "==> Configuring for $ARCH"
    CFLAGS="$CFLAGS_EXTRA -mmacosx-version-min=13.0" \
    LDFLAGS="$CFLAGS_EXTRA -mmacosx-version-min=13.0" \
    ./configure \
        --host="$HOST" \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-ogg --disable-cpplibs --disable-examples \
        --disable-doxygen-docs --disable-xmms-plugin \
        >/dev/null

    echo "==> Building $ARCH"
    make -j$(sysctl -n hw.ncpu) >/dev/null
    make install >/dev/null
    popd >/dev/null
}

build_arch arm64
build_arch x86_64

# -----------------------------------------------------------------
# Bundle into xcframework
# -----------------------------------------------------------------
HEADERS_DIR="$WORK/install-arm64/include"
LIB_ARM64="$WORK/install-arm64/lib/libFLAC.a"
LIB_X86="$WORK/install-x86_64/lib/libFLAC.a"

[ -f "$LIB_ARM64" ] || { echo "Missing arm64 lib"; exit 1; }
[ -f "$LIB_X86" ]   || { echo "Missing x86_64 lib"; exit 1; }
[ -d "$HEADERS_DIR/FLAC" ] || { echo "Missing FLAC headers"; exit 1; }

# Write module.modulemap so Swift can import CFLAC
MODULEMAP="$HEADERS_DIR/module.modulemap"
cat > "$MODULEMAP" <<'EOF'
module CFLAC {
    header "FLAC/all.h"
    link "FLAC"
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
echo "    .binaryTarget(name: \"CFLAC\", path: \"Frameworks/libFLAC.xcframework\")"
