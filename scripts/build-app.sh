#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build tools and caches stay in this checkout. This script never launches the
# app, the Discobox CLI, or a backend.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
export GOMODCACHE="$PWD/.build/go-mod-cache"
export GOCACHE="$PWD/.build/go-cache"
export GOTOOLCHAIN=local
mkdir -p "$GOCACHE" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
# Keep this local artifact independent of dsymutil's external cache writes.
# Debug builds (including tests and Xcode runs) retain their normal symbols.
swift build --disable-sandbox --cache-path .build/package-cache --configuration release -debug-info-format none
(
    cd Companion
    go build -trimpath -o ../.build/discobox-desktop-bridge .
)
APP="$PWD/dist/Discobox.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiscoboxDesktop "$APP/Contents/MacOS/DiscoboxDesktop"
cp .build/discobox-desktop-bridge "$APP/Contents/MacOS/discobox-desktop-bridge"
GHOSTTY_SDK="$PWD/.build/ghostty/sdk/6d2dd585a5d87fa745d48188dd096ca6e63014d0"
ditto "$GHOSTTY_SDK/Resources/ghostty" "$APP/Contents/Resources/ghostty"
cp "$GHOSTTY_SDK/LICENSE" "$APP/Contents/Resources/Ghostty-LICENSE"
bash scripts/build-icon.sh
cp .build/Discobox.icns "$APP/Contents/Resources/Discobox.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/discobox-desktop-bridge"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
