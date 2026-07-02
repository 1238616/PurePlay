#!/usr/bin/env bash
# Build a release PurePlay.app + installer DMG.
# Auto-bumps the patch version stored in VERSION on every run unless
# you override with: VERSION_PART=major|minor|patch ./scripts/build_release.sh
# or pass an explicit version: ./scripts/build_release.sh 1.5.0
#
# Signing modes (auto-detected):
#   1. If DEVELOPER_ID_APP env is set, or a "Developer ID Application" identity
#      exists in the login keychain, use hardened runtime + secure timestamp
#      + entitlements (Resources/PurePlay.entitlements) for proper distribution.
#   2. Otherwise fall back to ad-hoc signing (development only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
INFO_PLIST_TEMPLATE="$ROOT/Resources/Info.plist.template"
ENTITLEMENTS="$ROOT/Resources/PurePlay.entitlements"

[ -f "$VERSION_FILE" ] || echo "0.0.0" > "$VERSION_FILE"
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [ $# -ge 1 ]; then
    # Explicit version passed: use it
    NEW_VERSION="$1"
    echo "==> Setting version: $CURRENT -> $NEW_VERSION"
    echo "$NEW_VERSION" > "$VERSION_FILE"
elif [ -n "${VERSION_PART:-}" ]; then
    # VERSION_PART=major|minor|patch explicitly requested: bump
    IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"
    case "$VERSION_PART" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo "==> Bumping version: $CURRENT -> $NEW_VERSION (part=$VERSION_PART)"
    echo "$NEW_VERSION" > "$VERSION_FILE"
else
    # Default: keep current version (no auto-bump)
    NEW_VERSION="$CURRENT"
    echo "==> Using version: $NEW_VERSION (set VERSION_PART=major|minor|patch to bump)"
fi

# -----------------------------------------------------------------
# Ensure FFmpeg is built
# -----------------------------------------------------------------
FFMPEG_DIR="$ROOT/Frameworks/FFmpeg"
if [ ! -d "$FFMPEG_DIR/lib" ] || [ ! -d "$FFMPEG_DIR/include" ]; then
    echo "==> FFmpeg not found, building..."
    "$ROOT/scripts/build_ffmpeg.sh"
fi

echo "==> swift build -c release"
BUILD_FLAGS=()
if [ -d "$FFMPEG_DIR/lib" ] && [ -d "$FFMPEG_DIR/include" ]; then
    echo "    (with FFmpeg support)"
    BUILD_FLAGS+=(
        -Xcc -I"$FFMPEG_DIR/include"
        -Xcc -fmodule-map-file="$ROOT/Modules/CFFmpeg/module.modulemap"
        -Xswiftc -Xcc -Xswiftc -I"$FFMPEG_DIR/include"
        -Xswiftc -Xcc -Xswiftc -fmodule-map-file="$ROOT/Modules/CFFmpeg/module.modulemap"
        -Xlinker -L"$FFMPEG_DIR/lib"
        -Xlinker -lavcodec -Xlinker -lavformat -Xlinker -lavutil -Xlinker -lswresample
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    )
fi
swift build -c release --product PurePlay "${BUILD_FLAGS[@]}"

BIN="$ROOT/.build/release/PurePlay"
APP_BUILT="$ROOT/.build/release/PurePlay.app"
[ -x "$BIN" ] || { echo "Missing built binary at $BIN"; exit 1; }

# Assemble .app bundle if missing (e.g., after swift package clean)
if [ ! -d "$APP_BUILT" ]; then
    echo "==> Assembling app bundle"
    mkdir -p "$APP_BUILT/Contents/MacOS"
    mkdir -p "$APP_BUILT/Contents/Resources"
    if [ -d "$ROOT/dist/PurePlay.app" ]; then
        cp -R "$ROOT/dist/PurePlay.app/Contents/Info.plist" "$APP_BUILT/Contents/"
        cp -R "$ROOT/dist/PurePlay.app/Contents/Resources/"* "$APP_BUILT/Contents/Resources/" 2>/dev/null || true
    elif [ -f "$INFO_PLIST_TEMPLATE" ]; then
        cp "$INFO_PLIST_TEMPLATE" "$APP_BUILT/Contents/Info.plist"
    else
        cat > "$APP_BUILT/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PurePlay</string>
    <key>CFBundleIdentifier</key><string>com.pureplay.app</string>
    <key>CFBundleName</key><string>PurePlay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>0.0.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLISTEOF
    fi
fi

PLIST="$APP_BUILT/Contents/Info.plist"
echo "==> Updating Info.plist version -> $NEW_VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$PLIST"

# Sync project Resources/ into app bundle (icons, presets, etc.)
if [ -d "$ROOT/Resources" ]; then
    echo "==> Syncing Resources into app bundle"
    mkdir -p "$APP_BUILT/Contents/Resources"
    for res in "$ROOT/Resources"/*; do
        [ -e "$res" ] && cp -R "$res" "$APP_BUILT/Contents/Resources/"
    done
fi

echo "==> Refreshing executable inside bundle"
cp "$BIN" "$APP_BUILT/Contents/MacOS/PurePlay"

# -----------------------------------------------------------------
# Embed FFmpeg dylibs (if built)
# -----------------------------------------------------------------
if [ -d "$FFMPEG_DIR/lib" ]; then
    echo "==> Embedding FFmpeg dylibs"
    mkdir -p "$APP_BUILT/Contents/Frameworks"
    FFMPEG_LIBS="libavcodec libavformat libavutil libswresample"
    for lib in $FFMPEG_LIBS; do
        DYLIB=$(find "$FFMPEG_DIR/lib" -name "${lib}.dylib" | head -1)
        if [ -n "$DYLIB" ]; then
            cp "$DYLIB" "$APP_BUILT/Contents/Frameworks/"
            install_name_tool -id "@rpath/${lib}.dylib" "$APP_BUILT/Contents/Frameworks/${lib}.dylib"
        fi
    done

    # Rewrite versioned @rpath refs (e.g. libavutil.59.dylib) to unversioned
    # form and drop any homebrew libX11 dep that snuck in from FFmpeg configure.
    for lib in $FFMPEG_LIBS; do
        OUTLIB="$APP_BUILT/Contents/Frameworks/${lib}.dylib"
        [ -f "$OUTLIB" ] || continue
        for dep in $FFMPEG_LIBS; do
            [ "$lib" = "$dep" ] && continue
            while IFS= read -r OLD_PATH; do
                [ -z "$OLD_PATH" ] && continue
                install_name_tool -change "$OLD_PATH" "@rpath/${dep}.dylib" "$OUTLIB" 2>/dev/null || true
            done < <(otool -L "$OUTLIB" | awk '{print $1}' | grep "^@rpath/${dep}\." | grep -v "^@rpath/${dep}\.dylib$" | sort -u || true)
        done
        # Drop any homebrew libX11 dep that FFmpeg's configure auto-detected.
        # We don't ship X11 and don't call any of its symbols (--disable-everything
        # plus only audio decoders enabled), but the load command alone breaks
        # launch on machines without /opt/homebrew. Redirect to libSystem.
        while IFS= read -r BREW_PATH; do
            [ -z "$BREW_PATH" ] && continue
            install_name_tool -change "$BREW_PATH" "/usr/lib/libobjc.A.dylib" "$OUTLIB" 2>/dev/null || true
        done < <(otool -L "$OUTLIB" | awk '{print $1}' | grep "^/opt/homebrew/" | sort -u || true)
    done

    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUILT/Contents/MacOS/PurePlay" 2>/dev/null || true
fi

# -----------------------------------------------------------------
# Codesign — prefer Developer ID, fall back to ad-hoc
# -----------------------------------------------------------------
if [ -z "${DEVELOPER_ID_APP:-}" ]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning login.keychain 2>/dev/null \
        | awk -F'"' '/Developer ID Application:/ {print $2; exit}' || true)"
fi

if [ -n "$DEVELOPER_ID_APP" ]; then
    echo "==> Codesign with Developer ID: $DEVELOPER_ID_APP"
    SIGN_ARGS=(--force --options runtime --timestamp --deep --sign "$DEVELOPER_ID_APP")
    if [ -f "$ENTITLEMENTS" ]; then
        SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${SIGN_ARGS[@]}" "$APP_BUILT"
else
    echo "==> No Developer ID found; using ad-hoc signature (dev only)"
    codesign --force --deep --sign - "$APP_BUILT" >/dev/null
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUILT" 2>&1 | tail -5

DIST="$ROOT/dist"
mkdir -p "$DIST"

# -----------------------------------------------------------------
# dSYM bundle for crash symbolication
# -----------------------------------------------------------------
DSYM_BUNDLE="$DIST/PurePlay-${NEW_VERSION}.dSYM"
echo "==> Generating dSYM bundle"
[ -e "$DSYM_BUNDLE" ] && rm -rf "$DSYM_BUNDLE"
dsymutil "$APP_BUILT/Contents/MacOS/PurePlay" -o "$DSYM_BUNDLE" 2>&1 | tail -3 || true
if [ -d "$DSYM_BUNDLE" ]; then
    DSYM_ZIP="$DIST/PurePlay-${NEW_VERSION}.dSYM.zip"
    [ -f "$DSYM_ZIP" ] && rm -f "$DSYM_ZIP"
    ( cd "$DIST" && zip -qr "$(basename "$DSYM_ZIP")" "$(basename "$DSYM_BUNDLE")" )
    echo "    dSYM zip: $DSYM_ZIP"
fi

STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
if [ -d "$STAGE/PurePlay.app" ]; then
    /bin/rm -rf "$STAGE/PurePlay.app"
fi
cp -R "$APP_BUILT" "$STAGE/PurePlay.app"
ln -sfn /Applications "$STAGE/Applications"

if [ -d "$DIST/PurePlay.app" ]; then
    /bin/rm -rf "$DIST/PurePlay.app"
fi
cp -R "$APP_BUILT" "$DIST/PurePlay.app"

DMG="$DIST/PurePlay-${NEW_VERSION}-Installer.dmg"
[ -f "$DMG" ] && /bin/rm -f "$DMG"
echo "==> Creating DMG: $DMG"
hdiutil create -fs HFS+ -srcfolder "$STAGE" -volname "PurePlay $NEW_VERSION" -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null

# Sign the DMG with the same identity when present (notarytool prefers it)
if [ -n "$DEVELOPER_ID_APP" ]; then
    echo "==> Signing DMG"
    codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG"
fi

echo ""
echo "Build complete:"
echo "  Version : $NEW_VERSION"
echo "  App     : $DIST/PurePlay.app"
echo "  DMG     : $DMG"
if [ -n "$DEVELOPER_ID_APP" ]; then
    echo ""
    echo "Next: ./scripts/notarize.sh \"$DMG\""
fi
