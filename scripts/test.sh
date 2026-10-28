#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/dev-env.sh"
swift test --disable-sandbox --cache-path .build/package-cache
(
    cd Companion
    go test -race ./...
    go vet ./...
)
