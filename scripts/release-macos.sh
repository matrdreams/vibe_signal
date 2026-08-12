#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Vibe Signal.app"
INFO_PLIST="$ROOT/Resources/Info.plist"
SIGNING_IDENTITY="${VIBE_SIGNAL_SIGNING_IDENTITY:-Developer ID Application: Kun Zhao (3TBP5MLMTQ)}"
NOTARY_PROFILE="${VIBE_SIGNAL_NOTARY_PROFILE:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG="$DIST/Vibe-Signal-$VERSION-universal.dmg"

if [[ "${VIBE_SIGNAL_SKIP_BUILD:-0}" != "1" ]]; then
    "$ROOT/scripts/build-app.sh"
fi

if [[ ! -d "$APP" ]]; then
    echo "Missing app bundle: $APP" >&2
    exit 1
fi

sign() {
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$1"
}

# Sign nested Mach-O files first, then seal the outer application bundle.
sign "$APP/Contents/MacOS/libVibeSignalCore.dylib"
sign "$APP/Contents/MacOS/vibe-signal"
sign "$APP/Contents/MacOS/VibeSignalApp"
sign "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

STAGING="$(mktemp -d "$DIST/dmg-staging.XXXXXX")"
cleanup() {
    if [[ -d "$STAGING" ]]; then
        rm -r "$STAGING"
    fi
}
trap cleanup EXIT

ditto "$APP" "$STAGING/Vibe Signal.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Vibe Signal" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG"

sign "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "Notarization skipped: set VIBE_SIGNAL_NOTARY_PROFILE to a notarytool keychain profile." >&2
fi

echo "app: $APP"
echo "dmg: $DMG"
echo "version: $VERSION ($BUILD_NUMBER)"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
