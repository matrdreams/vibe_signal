#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
TARGET="${TARGET:-$(uname -m)-apple-macosx13.0}"
BUILD="$ROOT/.build/manual/$CONFIGURATION"
MODULE_CACHE="$BUILD/ModuleCache"
DIST="$ROOT/dist"
APP="$DIST/Vibe Signal.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$BUILD" "$MODULE_CACHE" "$MACOS" "$RESOURCES"

CORE_SOURCES=("$ROOT"/Sources/VibeSignalCore/*.swift)
APP_SOURCES=("$ROOT"/Sources/VibeSignalApp/*.swift)

SWIFT_FLAGS=(
    -swift-version 5
    -target "$TARGET"
    -module-cache-path "$MODULE_CACHE"
)

if [[ "$CONFIGURATION" == "release" ]]; then
    SWIFT_FLAGS+=(-O)
else
    SWIFT_FLAGS+=(-Onone -g)
fi

swiftc "${SWIFT_FLAGS[@]}" \
    -emit-library \
    -emit-module \
    -module-name VibeSignalCore \
    -emit-module-path "$BUILD/VibeSignalCore.swiftmodule" \
    -Xlinker -install_name \
    -Xlinker @rpath/libVibeSignalCore.dylib \
    "${CORE_SOURCES[@]}" \
    -o "$BUILD/libVibeSignalCore.dylib"

swiftc "${SWIFT_FLAGS[@]}" \
    -parse-as-library \
    -I "$BUILD" \
    -L "$BUILD" \
    -lVibeSignalCore \
    -Xlinker -rpath \
    -Xlinker @executable_path \
    "$ROOT/Sources/VibeSignalCLI/main.swift" \
    -o "$BUILD/vibe-signal"

swiftc "${SWIFT_FLAGS[@]}" \
    -I "$BUILD" \
    -L "$BUILD" \
    -lVibeSignalCore \
    -Xlinker -rpath \
    -Xlinker @executable_path \
    "${APP_SOURCES[@]}" \
    -o "$BUILD/VibeSignalApp"

cp "$BUILD/VibeSignalApp" "$MACOS/VibeSignalApp"
cp "$BUILD/libVibeSignalCore.dylib" "$MACOS/libVibeSignalCore.dylib"
cp "$BUILD/vibe-signal" "$DIST/vibe-signal"
cp "$BUILD/libVibeSignalCore.dylib" "$DIST/libVibeSignalCore.dylib"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
chmod +x "$MACOS/VibeSignalApp" "$DIST/vibe-signal"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi

echo "$APP"
echo "$DIST/vibe-signal"
