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

if [[ -n "${TARGET:-}" ]]; then
    TARGETS=("$TARGET")
else
    read -r -a ARCHITECTURES <<< "${VIBE_SIGNAL_ARCHS:-arm64 x86_64}"
    if [[ "${#ARCHITECTURES[@]}" -eq 0 ]]; then
        echo "VIBE_SIGNAL_ARCHS must contain at least one architecture." >&2
        exit 1
    fi

    TARGETS=()
    for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
        case "$ARCHITECTURE" in
            arm64|x86_64)
                TARGETS+=("$ARCHITECTURE-apple-macosx13.0")
                ;;
            *)
                echo "Unsupported architecture: $ARCHITECTURE (expected arm64 or x86_64)" >&2
                exit 1
                ;;
        esac
    done
fi

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

APP_BINARIES=()
CLI_BINARIES=()
CORE_LIBRARIES=()

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

    APP_BINARIES+=("$architecture_build/VibeSignalApp")
    CLI_BINARIES+=("$architecture_build/vibe-signal")
    CORE_LIBRARIES+=("$architecture_build/libVibeSignalCore.dylib")
}

merge_or_copy() {
    local output="$1"
    shift

    if [[ "$#" -eq 1 ]]; then
        cp "$1" "$output"
        return
    fi

    local temporary_directory
    temporary_directory="$(mktemp -d "$BUILD/lipo.XXXXXX")"
    lipo -create "$@" -output "$temporary_directory/merged"
    mv "$temporary_directory/merged" "$output"
    rmdir "$temporary_directory"
}

verify_architectures() {
    local binary="$1"
    local target
    local architecture

    for target in "${TARGETS[@]}"; do
        architecture="${target%%-*}"
        if ! lipo "$binary" -verify_arch "$architecture"; then
            echo "Missing $architecture slice in $binary" >&2
            exit 1
        fi
    done
}

for TARGET_TRIPLE in "${TARGETS[@]}"; do
    build_target "$TARGET_TRIPLE"
done

merge_or_copy "$BUILD/VibeSignalApp" "${APP_BINARIES[@]}"
merge_or_copy "$BUILD/vibe-signal" "${CLI_BINARIES[@]}"
merge_or_copy "$BUILD/libVibeSignalCore.dylib" "${CORE_LIBRARIES[@]}"

verify_architectures "$BUILD/VibeSignalApp"
verify_architectures "$BUILD/vibe-signal"
verify_architectures "$BUILD/libVibeSignalCore.dylib"

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
echo "architectures: $(lipo -archs "$BUILD/VibeSignalApp")"
