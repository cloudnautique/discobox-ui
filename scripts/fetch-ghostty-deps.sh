#!/bin/bash
# Seed the exact dependency hash so Zig 0.14 need not use Codeberg's Git protocol.
set -euo pipefail
cd "$(dirname "$0")/.."
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.build/ghostty/global-cache}"
ZG_HASH=zg-0.13.4-AAAAAGiZ7QLz4pvECFa_wG4O4TP4FLABHHbemH2KakWM
ZG_REVISION=4a002763419a34d61dcbb1f415821b83b9bf8ddc

if [[ -d "$ZIG_GLOBAL_CACHE_DIR/p/$ZG_HASH" ]]; then
    exit 0
fi

mkdir -p "$ZIG_GLOBAL_CACHE_DIR/downloads"
download_dir=$(mktemp -d "$ZIG_GLOBAL_CACHE_DIR/downloads/zg.XXXXXX")
trap 'rm -rf "$download_dir"' EXIT
archive="$download_dir/zg.tar.gz"
printf 'Fetching pinned zg dependency from GitHub.\n'
curl --fail --location --retry 3 --connect-timeout 30 --max-time 180 \
    "https://codeload.github.com/pfgithub/zg/tar.gz/$ZG_REVISION" --output "$archive"
actual=$(zig fetch "$archive")
if [[ "$actual" != "$ZG_HASH" ]]; then
    printf 'zg package hash mismatch; refusing to use the mirror archive. Expected %s, got %s.\n' "$ZG_HASH" "$actual" >&2
    exit 1
fi
printf 'Verified zg package hash: %s\n' "$actual"
