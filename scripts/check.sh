#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/dev-env.sh"

case "${1:-}" in
    lint)
        # Use the compiler's Swift diagnostics without imposing a new source style.
        swift build --disable-sandbox --cache-path .build/package-cache -Xswiftc -warnings-as-errors
        unformatted=$(gofmt -l Companion/*.go)
        if [[ -n "$unformatted" ]]; then
            printf 'Go files need formatting (run make fmt-go):\n%s\n' "$unformatted" >&2
            exit 1
        fi
        for script in scripts/*.sh; do bash -n "$script"; done
        python3 - <<'PY'
import ast
from pathlib import Path
for path in Path("scripts").glob("*.py"):
    ast.parse(path.read_text(), filename=str(path))
PY
        plutil -lint Resources/Info.plist
        git diff --check
        git diff --cached --check
        ;;
    vet)
        (cd Companion && go vet ./...)
        ;;
    fmt-go)
        gofmt -w Companion/*.go
        ;;
    verify)
        if [[ ! -d dist/Discobox.app ]]; then
            printf 'No app bundle found. Run make build first.\n' >&2
            exit 1
        fi
        codesign --verify --deep --strict dist/Discobox.app
        plutil -lint dist/Discobox.app/Contents/Info.plist
        ;;
    *)
        printf 'Usage: %s {lint|vet|fmt-go|verify}\n' "$0" >&2
        exit 2
        ;;
esac
