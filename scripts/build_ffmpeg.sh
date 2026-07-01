#!/usr/bin/env bash
# Build FFmpeg shared libraries for macOS (arm64 + x86_64).
#
# Output: Frameworks/FFmpeg/{lib,include}
#   - libavcodec.dylib, libavformat.dylib, libavutil.dylib, libswresample.dylib
#   - Universal (fat) binaries
#
# Prerequisites:
#   - Xcode command line tools (clang, lipo, install_name_tool)
#   - nasm (brew install nasm) — optional, for x86_64 asm optimizations
#
# Run:
#   ./scripts/build_ffmpeg.sh [version]
# Default version: 7.1
#
# After build, the Sources/CFFmpeg module map references these paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-7.1}"
WORK="$ROOT/.build/ffmpeg-build"
OUTDIR="$ROOT/Frameworks/FFmpeg"

MIN_MACOS="13.0"

mkdir -p "$WORK"
cd "$WORK"

TARBALL="ffmpeg-$VERSION.tar.xz"
URL="https://ffmpeg.org/releases/$TARBALL"
if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading $URL"
    curl -L -o "$TARBALL" "$URL"
fi

if [ ! -d "ffmpeg-$VERSION" ]; then
    echo "==> Extracting"
    tar -xf "$TARBALL"
fi

COMMON_FLAGS="
    --disable-static
    --enable-shared
    --disable-programs
    --disable-doc
    --disable-everything
    --disable-network
    --disable-avdevice
    --disable-swscale
    --disable-avfilter
    --disable-postproc
    --disable-xlib
    --disable-libxcb
    --enable-demuxer=ape,wv,tta,ogg,opus,flac,wav,aiff,dsf,mov,mp3,aac,asf,matroska
    --enable-decoder=ape,wavpack,tta,opus,vorbis,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32le,mp3,aac,alac,wmalossless,wmapro,wmav2,wmav1,wmavoice
    --enable-parser=flac,opus,vorbis,mpegaudio,aac
    --enable-protocol=file
    --disable-debug
    --enable-optimizations
    --disable-asm
"

build_arch() {
    local ARCH="$1"
    local PREFIX="$WORK/install-$ARCH"

    if [ -f "$PREFIX/lib/libavcodec.dylib" ]; then
        echo "==> $ARCH already built, skipping"
        return
    fi

    echo "==> Configuring FFmpeg $VERSION for $ARCH"
    cd "$WORK/ffmpeg-$VERSION"
    make distclean 2>/dev/null || true

    local ARCH_FLAGS=""
    local EXTRA_CFLAGS="-mmacosx-version-min=$MIN_MACOS"
    local EXTRA_LDFLAGS="-mmacosx-version-min=$MIN_MACOS"
    case "$ARCH" in
        arm64)
            ARCH_FLAGS="--arch=aarch64 --enable-cross-compile --target-os=darwin"
            EXTRA_CFLAGS="$EXTRA_CFLAGS -arch arm64"
            EXTRA_LDFLAGS="$EXTRA_LDFLAGS -arch arm64"
            ;;
        x86_64)
            ARCH_FLAGS="--arch=x86_64 --enable-cross-compile --target-os=darwin"
            EXTRA_CFLAGS="$EXTRA_CFLAGS -arch x86_64"
            EXTRA_LDFLAGS="$EXTRA_LDFLAGS -arch x86_64"
            ;;
    esac

    ./configure \
        --prefix="$PREFIX" \
        $COMMON_FLAGS \
        $ARCH_FLAGS \
        --cc=clang \
        --extra-cflags="$EXTRA_CFLAGS" \
        --extra-ldflags="$EXTRA_LDFLAGS" \
        --install-name-dir="@rpath"

    echo "==> Building FFmpeg $VERSION for $ARCH"
    make -j$(sysctl -n hw.ncpu)
    make install
    cd "$WORK"
}

build_arch arm64
build_arch x86_64

# -----------------------------------------------------------------
# Create universal (fat) dylibs
# -----------------------------------------------------------------
echo "==> Creating universal dylibs"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/lib" "$OUTDIR/include"

LIBS="libavcodec libavformat libavutil libswresample"

for lib in $LIBS; do
    ARM_LIB=$(find "$WORK/install-arm64/lib" -name "${lib}.*.*.*.dylib" | head -1)
    X86_LIB=$(find "$WORK/install-x86_64/lib" -name "${lib}.*.*.*.dylib" | head -1)

    if [ -z "$ARM_LIB" ] || [ -z "$X86_LIB" ]; then
        echo "ERROR: Missing $lib dylib for one architecture"
        exit 1
    fi

    OUTLIB="$OUTDIR/lib/${lib}.dylib"
    lipo -create "$ARM_LIB" "$X86_LIB" -output "$OUTLIB"
    install_name_tool -id "@rpath/${lib}.dylib" "$OUTLIB"
    echo "  Created: $OUTLIB"
done

# Fix inter-library references (rewrite all versioned @rpath refs to unversioned)
for lib in $LIBS; do
    OUTLIB="$OUTDIR/lib/${lib}.dylib"
    for dep in $LIBS; do
        if [ "$lib" != "$dep" ]; then
            OLD_PATHS=$(otool -L "$OUTLIB" | awk '{print $1}' | grep "^@rpath/${dep}\." | grep -v "^@rpath/${dep}\.dylib$" | sort -u)
            for OLD_PATH in $OLD_PATHS; do
                echo "  Fix: $lib -> ${dep}: $OLD_PATH -> @rpath/${dep}.dylib"
                install_name_tool -change "$OLD_PATH" "@rpath/${dep}.dylib" "$OUTLIB"
            done
        fi
    done
done

# Copy headers
cp -R "$WORK/install-arm64/include/libavcodec" "$OUTDIR/include/"
cp -R "$WORK/install-arm64/include/libavformat" "$OUTDIR/include/"
cp -R "$WORK/install-arm64/include/libavutil" "$OUTDIR/include/"
cp -R "$WORK/install-arm64/include/libswresample" "$OUTDIR/include/"

echo ""
echo "==> FFmpeg build complete"
echo "  Libraries: $OUTDIR/lib/"
echo "  Headers:   $OUTDIR/include/"
echo ""
echo "  To use in PurePlay:"
echo "    1. swift build -Xcc -I$OUTDIR/include -Xlinker -L$OUTDIR/lib"
echo "    2. Or set PKG_CONFIG_PATH and use the CFFmpeg system library target"
