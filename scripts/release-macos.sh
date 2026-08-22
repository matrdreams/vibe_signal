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
DMG="$DIST/Vibe-Signal-$VERSION-arm64.dmg"
NOTARY_ARCHIVE="$DIST/Vibe-Signal-$VERSION-notarization.zip"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
KEEP_RELEASE_APP="${VIBE_SIGNAL_KEEP_RELEASE_APP:-0}"

if [[ -z "$NOTARY_PROFILE" ]]; then
    cat >&2 <<'EOF'
Missing VIBE_SIGNAL_NOTARY_PROFILE.

Public releases must be notarized. Store Apple notary credentials in the
Keychain first, then rerun this script with the profile name, for example:

  xcrun notarytool store-credentials VibeSignalNotary \
    --apple-id "YOUR_APPLE_ID" \
    --team-id "3TBP5MLMTQ"
  VIBE_SIGNAL_NOTARY_PROFILE=VibeSignalNotary ./scripts/release-macos.sh
EOF
    exit 1
fi

if [[ "${VIBE_SIGNAL_SKIP_BUILD:-0}" != "1" ]]; then
    "$ROOT/scripts/build-app.sh"
fi

if [[ ! -d "$APP" ]]; then
    echo "Missing app bundle: $APP" >&2
    exit 1
fi

verify_arm64_only() {
    local binary="$1"
    local architectures

    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" != "arm64" ]]; then
        echo "Release binaries must be arm64-only; found '$architectures': $binary" >&2
        exit 1
    fi
}

verify_arm64_only "$APP/Contents/MacOS/libVibeSignalCore.dylib"
verify_arm64_only "$APP/Contents/MacOS/vibe-signal"
verify_arm64_only "$APP/Contents/MacOS/VibeSignalApp"

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

# Notarize and staple the app itself before placing it in the disk image. This
# keeps the installed copy verifiable even when the Mac cannot contact Apple.
rm -f "$NOTARY_ARCHIVE"
ditto -c -k --keepParent "$APP" "$NOTARY_ARCHIVE"
xcrun notarytool submit "$NOTARY_ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
rm -f "$NOTARY_ARCHIVE"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

STAGING="$(mktemp -d "$DIST/dmg-staging.XXXXXX")"
cleanup() {
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$STAGING/Vibe Signal.app" >/dev/null 2>&1 || true
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
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

xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

if [[ "$KEEP_RELEASE_APP" != "1" ]]; then
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
    rm -r "$APP"
    APP_RESULT="packaged inside $DMG (loose app removed)"
else
    APP_RESULT="$APP"
fi

echo "app: $APP_RESULT"
echo "dmg: $DMG"
echo "version: $VERSION ($BUILD_NUMBER)"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
