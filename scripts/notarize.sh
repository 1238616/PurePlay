#!/usr/bin/env bash
# Sign + Notarize PurePlay.app / DMG for distribution outside the App Store.
#
# Prerequisites:
#   1. Developer ID Application certificate installed in login keychain.
#   2. Either:
#       (a) An "AC_PROFILE" keychain item set up via:
#           xcrun notarytool store-credentials AC_PROFILE \
#               --apple-id you@example.com --team-id ABCDE12345 \
#               --password "app-specific-password"
#      or (b) Export these env vars before running:
#           AC_APPLE_ID="you@example.com"
#           AC_TEAM_ID="ABCDE12345"
#           AC_PASSWORD="app-specific-password"   # NOT your Apple ID password
#   3. Optional: DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
#      Auto-detected from keychain if a single matching identity exists.
#
# Usage:
#   ./scripts/notarize.sh [path/to/PurePlay.app-or-PurePlay.dmg]
#   If no path provided, defaults to dist/PurePlay-<VERSION>-Installer.dmg
#
# This script:
#   - Signs the .app with Developer ID + hardened runtime + secure timestamp
#   - Sends to Apple notary service (notarytool submit --wait)
#   - On success: staples the ticket so Gatekeeper accepts offline
#
# After running, share the stapled .dmg directly with end users.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    TARGET="$DIST/PurePlay-${VERSION}-Installer.dmg"
fi
[ -e "$TARGET" ] || { echo "Target not found: $TARGET"; exit 1; }

# -----------------------------------------------------------------
# 1. Pick Developer ID identity
# -----------------------------------------------------------------
if [ -z "${DEVELOPER_ID_APP:-}" ]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning login.keychain 2>/dev/null \
        | awk -F'"' '/Developer ID Application:/ {print $2; exit}' || true)"
fi
if [ -z "$DEVELOPER_ID_APP" ]; then
    echo "ERROR: No 'Developer ID Application' identity found in keychain."
    echo "Install your Developer ID certificate from developer.apple.com."
    exit 1
fi
echo "==> Signing identity: $DEVELOPER_ID_APP"

ENTITLEMENTS="$ROOT/Resources/PurePlay.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "==> No entitlements found, generating minimal default."
    cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <false/>
</dict>
</plist>
PLIST
fi

# -----------------------------------------------------------------
# 2. Sign the target
# -----------------------------------------------------------------
sign_app() {
    local app="$1"
    echo "==> Signing $app"
    # Sign nested frameworks/dylibs first (deep), then the bundle.
    codesign --force --options runtime --timestamp --deep \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID_APP" "$app"
    codesign --verify --strict --verbose=2 "$app"
}

ARTIFACT_DMG=""
ARTIFACT_APP=""

if [[ "$TARGET" == *.app ]]; then
    sign_app "$TARGET"
    ARTIFACT_APP="$TARGET"
elif [[ "$TARGET" == *.dmg ]]; then
    # Mount, sign the .app inside, recreate DMG, then notarize the DMG.
    MNT="$(mktemp -d)"
    echo "==> Mounting $TARGET"
    hdiutil attach -nobrowse -mountpoint "$MNT" "$TARGET" >/dev/null
    INNER_APP="$MNT/PurePlay.app"
    [ -d "$INNER_APP" ] || { echo "ERROR: PurePlay.app not in DMG"; hdiutil detach "$MNT" >/dev/null; exit 1; }

    # Copy out, sign, then repackage (DMGs are read-only after creation).
    WORK="$(mktemp -d)"
    cp -R "$INNER_APP" "$WORK/PurePlay.app"
    hdiutil detach "$MNT" >/dev/null
    sign_app "$WORK/PurePlay.app"

    # Recreate DMG with signed app
    REPACKED="$DIST/PurePlay-${VERSION}-Signed.dmg"
    [ -f "$REPACKED" ] && rm -f "$REPACKED"
    ln -sfn /Applications "$WORK/Applications"
    echo "==> Recreating signed DMG: $REPACKED"
    hdiutil create -fs HFS+ -srcfolder "$WORK" -volname "PurePlay $VERSION" \
        -format UDZO -imagekey zlib-level=9 "$REPACKED" >/dev/null
    rm -rf "$WORK"
    ARTIFACT_DMG="$REPACKED"
    ARTIFACT_APP="$WORK/PurePlay.app"

    # Sign the DMG itself
    codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$REPACKED"
else
    echo "ERROR: Target must be .app or .dmg, got: $TARGET"
    exit 1
fi

# -----------------------------------------------------------------
# 3. Submit to Apple notary service
# -----------------------------------------------------------------
NOTARY_ARGS=()
if [ -n "${AC_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$AC_PROFILE")
elif [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_TEAM_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ]; then
    NOTARY_ARGS=(--apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD")
else
    echo "ERROR: Set AC_PROFILE (keychain) or AC_APPLE_ID/AC_TEAM_ID/AC_PASSWORD."
    exit 1
fi

NOTARY_TARGET="${ARTIFACT_DMG:-$ARTIFACT_APP}"
echo "==> Submitting to notary service: $NOTARY_TARGET"
xcrun notarytool submit "$NOTARY_TARGET" "${NOTARY_ARGS[@]}" --wait

# -----------------------------------------------------------------
# 4. Staple
# -----------------------------------------------------------------
echo "==> Stapling ticket"
xcrun stapler staple "$NOTARY_TARGET"
xcrun stapler validate "$NOTARY_TARGET"

echo ""
echo "✓ Notarized & stapled:"
echo "  $NOTARY_TARGET"
echo ""
echo "Verify with:"
echo "  spctl --assess --type open --context context:primary-signature -vvv $NOTARY_TARGET"
