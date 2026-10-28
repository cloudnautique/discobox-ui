#!/bin/bash
set -euo pipefail
# This script builds artifacts only; it never launches the app or backend.
source "$(dirname "$0")/dev-env.sh"
# Keep this local artifact independent of dsymutil's external cache writes.
# Debug builds (including tests and Xcode runs) retain their normal symbols.
swift build --disable-sandbox --cache-path .build/package-cache --configuration release -debug-info-format none
(
    cd Companion
    go build -tags iroh_nolibs -trimpath -o ../.build/discobox-desktop-bridge .
)
APP="$PWD/dist/Discobox.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiscoboxDesktop "$APP/Contents/MacOS/DiscoboxDesktop"
cp .build/discobox-desktop-bridge "$APP/Contents/MacOS/discobox-desktop-bridge"
# Ship a signed native Iroh library instead of extracting executable code at runtime.
IROH_PLATFORM="darwin_$(go env GOARCH)"
IROH_MODULE=$(cd Companion && go list -m -f '{{.Dir}}' "github.com/discobox-ai/iroh-go/libs/$IROH_PLATFORM")
mkdir -p "$APP/Contents/Frameworks"
install -m 755 "$IROH_MODULE/lib/iroh_go.lib" "$APP/Contents/Frameworks/libiroh_go.dylib"
IROH_SOURCE=$(cd Companion && go list -m -f '{{.Dir}}' github.com/discobox-ai/iroh-go)
install -m 644 "$IROH_SOURCE/README.md" "$APP/Contents/Resources/Iroh-Go-README.md"
codesign --force --sign - "$APP/Contents/Frameworks/libiroh_go.dylib"
GHOSTTY_SDK="$PWD/.build/ghostty/sdk/6d2dd585a5d87fa745d48188dd096ca6e63014d0"
ditto "$GHOSTTY_SDK/Resources/ghostty" "$APP/Contents/Resources/ghostty"
cp "$GHOSTTY_SDK/LICENSE" "$APP/Contents/Resources/Ghostty-LICENSE"
bash scripts/build-icon.sh
cp .build/Discobox.icns "$APP/Contents/Resources/Discobox.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/discobox-desktop-bridge"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
