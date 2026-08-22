#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD="$ROOT/.build/manual/$CONFIGURATION"
DIST="$ROOT/dist"
APP="$DIST/Vibe Signal.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
TARGET="arm64-apple-macosx13.0"

# The generated app uses the same bundle identifier as the installed app.
# Keep the staging directory out of Spotlight so Apps/Launchpad does not show
# the build artifact as a second installed copy.
mkdir -p "$DIST"
touch "$DIST/.metadata_never_index"
mkdir -p "$BUILD" "$MACOS" "$RESOURCES"

CORE_SOURCES=("$ROOT"/Sources/VibeSignalCore/*.swift)
APP_SOURCES=("$ROOT"/Sources/VibeSignalApp/*.swift)

if [[ "$CONFIGURATION" == "release" ]]; then
    OPTIMIZATION_FLAGS=(-O)
else
    OPTIMIZATION_FLAGS=(-Onone -g)
fi

build_target() {
    local target="$1"
    local architecture="${target%%-*}"
    local architecture_build="$BUILD/$architecture"
    local module_cache="$architecture_build/ModuleCache"
    local swift_flags=(
        -swift-version 5
        -target "$target"
        -module-cache-path "$module_cache"
        "${OPTIMIZATION_FLAGS[@]}"
    )

    mkdir -p "$architecture_build" "$module_cache"

    swiftc "${swift_flags[@]}" \
        -emit-library \
        -emit-module \
        -module-name VibeSignalCore \
        -emit-module-path "$architecture_build/VibeSignalCore.swiftmodule" \
        -Xlinker -install_name \
        -Xlinker @rpath/libVibeSignalCore.dylib \
        "${CORE_SOURCES[@]}" \
        -o "$architecture_build/libVibeSignalCore.dylib"

    swiftc "${swift_flags[@]}" \
        -parse-as-library \
        -I "$architecture_build" \
        -L "$architecture_build" \
        -lVibeSignalCore \
        -Xlinker -rpath \
        -Xlinker @executable_path \
        "$ROOT/Sources/VibeSignalCLI/main.swift" \
        -o "$architecture_build/vibe-signal"

    swiftc "${swift_flags[@]}" \
        -I "$architecture_build" \
        -L "$architecture_build" \
        -lVibeSignalCore \
        -Xlinker -rpath \
        -Xlinker @executable_path \
        "${APP_SOURCES[@]}" \
        -o "$architecture_build/VibeSignalApp"

}

verify_arm64_only() {
    local binary="$1"
    local architectures

    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" != "arm64" ]]; then
        echo "Expected an arm64-only binary, found '$architectures': $binary" >&2
        exit 1
    fi
}

build_target "$TARGET"
cp "$BUILD/arm64/VibeSignalApp" "$BUILD/VibeSignalApp"
cp "$BUILD/arm64/vibe-signal" "$BUILD/vibe-signal"
cp "$BUILD/arm64/libVibeSignalCore.dylib" "$BUILD/libVibeSignalCore.dylib"

verify_arm64_only "$BUILD/VibeSignalApp"
verify_arm64_only "$BUILD/vibe-signal"
verify_arm64_only "$BUILD/libVibeSignalCore.dylib"

cp "$BUILD/VibeSignalApp" "$MACOS/VibeSignalApp"
cp "$BUILD/libVibeSignalCore.dylib" "$MACOS/libVibeSignalCore.dylib"
cp "$BUILD/vibe-signal" "$MACOS/vibe-signal"
cp "$BUILD/vibe-signal" "$DIST/vibe-signal"
cp "$BUILD/libVibeSignalCore.dylib" "$DIST/libVibeSignalCore.dylib"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
"$ROOT/scripts/generate-app-icon.sh" \
    "$ROOT/Resources/AppIcon.png" \
    "$RESOURCES" >/dev/null
chmod +x "$MACOS/VibeSignalApp" "$MACOS/vibe-signal" "$DIST/vibe-signal"

if [[ -d "$CONTENTS/_CodeSignature" ]]; then
    rm -r "$CONTENTS/_CodeSignature"
fi

if [[ "${VIBE_SIGNAL_ADHOC_SIGN:-0}" == "1" ]] && command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$DIST/libVibeSignalCore.dylib" >/dev/null 2>&1
    codesign --force --sign - "$DIST/vibe-signal" >/dev/null 2>&1
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi

# Building an application bundle can make Launch Services discover it even
# when it is never opened. Keep only the copy installed under /Applications in
# the macOS app launcher.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
fi

echo "$APP"
echo "$DIST/vibe-signal"
echo "architecture: $(lipo -archs "$BUILD/VibeSignalApp")"
