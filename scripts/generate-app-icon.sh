#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/Resources/AppIcon.png}"
OUTPUT_DIRECTORY="${2:-$ROOT/.build/generated-icon}"
MODULE_CACHE="$ROOT/.build/icon-module-cache"

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/vibe-signal-icon.XXXXXX")"
ASSET_CATALOG="$TEMPORARY_DIRECTORY/Assets.xcassets"
APP_ICON_SET="$ASSET_CATALOG/AppIcon.appiconset"
PARTIAL_INFO_PLIST="$TEMPORARY_DIRECTORY/asset-info.plist"

cleanup() {
    rm -r "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

mkdir -p "$APP_ICON_SET" "$OUTPUT_DIRECTORY" "$MODULE_CACHE"

cp "$ROOT/Resources/Assets.xcassets/Contents.json" \
    "$ASSET_CATALOG/Contents.json"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" \
    "$APP_ICON_SET/Contents.json"

xcrun swift \
    -module-cache-path "$MODULE_CACHE" \
    "$ROOT/scripts/render-app-icon.swift" \
    "$SOURCE" \
    "$APP_ICON_SET"

xcrun actool \
    --compile "$OUTPUT_DIRECTORY" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL_INFO_PLIST" \
    "$ASSET_CATALOG" >/dev/null

for compiled_asset in AppIcon.icns Assets.car; do
    if [[ ! -f "$OUTPUT_DIRECTORY/$compiled_asset" ]]; then
        echo "Asset catalog did not produce $compiled_asset." >&2
        exit 1
    fi
done

echo "$OUTPUT_DIRECTORY/AppIcon.icns"
echo "$OUTPUT_DIRECTORY/Assets.car"
