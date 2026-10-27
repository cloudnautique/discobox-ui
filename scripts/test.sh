#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
export GOMODCACHE="$PWD/.build/go-mod-cache"
export GOCACHE="$PWD/.build/go-cache"
export GOTOOLCHAIN=local
mkdir -p "$GOCACHE" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift test --disable-sandbox --cache-path .build/package-cache
(
    cd Companion
    go test -race ./...
    go vet ./...
)
