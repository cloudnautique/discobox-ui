#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Original Discobox brand mark; use the repository artwork without redrawing it.
ICONSET="$PWD/.build/Discobox.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" discobox/assets/brand/favicon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" discobox/assets/brand/favicon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/Discobox.icns
