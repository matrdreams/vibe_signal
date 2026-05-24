#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:-$(uname -m)-apple-macosx13.0}"
BUILD="$ROOT/.build/manual/test"
MODULE_CACHE="$BUILD/ModuleCache"

mkdir -p "$BUILD" "$MODULE_CACHE"

CORE_SOURCES=("$ROOT"/Sources/VibeSignalCore/*.swift)
SWIFT_FLAGS=(
    -swift-version 5
    -target "$TARGET"
    -module-cache-path "$MODULE_CACHE"
    -Onone
    -g
)

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
    -I "$BUILD" \
    -L "$BUILD" \
    -lVibeSignalCore \
    -Xlinker -rpath \
    -Xlinker @executable_path \
    "$ROOT/Tests/VibeSignalCoreManualTests/main.swift" \
    -o "$BUILD/VibeSignalCoreManualTests"

"$BUILD/VibeSignalCoreManualTests"
