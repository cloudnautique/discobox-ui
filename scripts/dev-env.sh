#!/bin/bash
# Source from build/check scripts. All tool caches stay inside the checkout.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
export GOMODCACHE="$PWD/.build/go-mod-cache"
export GOCACHE="$PWD/.build/go-cache"
export GOTOOLCHAIN=local
export IROH_GO_CACHE_DIR="$PWD/.build/iroh-cache"
mkdir -p "$GOCACHE" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
