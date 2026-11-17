#!/bin/bash
set -euo pipefail
# Separate fixture bundle; never placed in dist or included in a release archive.
source "$(dirname "$0")/dev-env.sh"
swift build --product DiscoboxSmoke --configuration debug --disable-sandbox --cache-path .build/package-cache
(
    cd Companion
    go build -tags iroh_nolibs -trimpath -o ../.build/discobox-smoke-bridge .
)
SMOKE_APP="$PWD/.build/DiscoboxSmoke.app"
SMOKE_SDK="$PWD/.build/ghostty/sdk/6d2dd585a5d87fa745d48188dd096ca6e63014d0"
mkdir -p "$SMOKE_APP/Contents/MacOS" "$SMOKE_APP/Contents/Resources" "$SMOKE_APP/Contents/Frameworks"
cp .build/debug/DiscoboxSmoke "$SMOKE_APP/Contents/MacOS/DiscoboxSmoke"
cp .build/discobox-smoke-bridge "$SMOKE_APP/Contents/MacOS/discobox-desktop-bridge"
SMOKE_IROH_PLATFORM="darwin_$(go env GOARCH)"
SMOKE_IROH_MODULE=$(cd Companion && go list -m -f '{{.Dir}}' "github.com/discobox-ai/iroh-go/libs/$SMOKE_IROH_PLATFORM")
install -m 755 "$SMOKE_IROH_MODULE/lib/iroh_go.lib" "$SMOKE_APP/Contents/Frameworks/libiroh_go.dylib"
ditto "$SMOKE_SDK/Resources/ghostty" "$SMOKE_APP/Contents/Resources/ghostty"
ditto Resources/Fonts "$SMOKE_APP/Contents/Resources/Fonts"
cp Resources/Smoke-Info.plist "$SMOKE_APP/Contents/Info.plist"
codesign --force --sign - "$SMOKE_APP/Contents/Frameworks/libiroh_go.dylib"
codesign --force --sign - "$SMOKE_APP/Contents/MacOS/discobox-desktop-bridge"
codesign --force --sign - "$SMOKE_APP"
printf 'Built %s\n' "$SMOKE_APP"
