#!/bin/bash
# Print one executable path. Do not install tools or change the user's PATH.
set -euo pipefail

if [[ -n "${GHOSTTY_LLVM_LIBTOOL:-}" ]]; then
    if [[ "$GHOSTTY_LLVM_LIBTOOL" == /* && -x "$GHOSTTY_LLVM_LIBTOOL" && -f "$GHOSTTY_LLVM_LIBTOOL" ]]; then
        printf '%s\n' "$GHOSTTY_LLVM_LIBTOOL"
        exit 0
    fi
    printf 'GHOSTTY_LLVM_LIBTOOL must name an executable absolute path.\n' >&2
    exit 1
fi

candidate=$(command -v llvm-libtool-darwin || true)
if [[ "$candidate" == /* && -x "$candidate" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
fi

# The utility is not included with every Xcode release. xcrun can also find
# tools supplied through PATH, so its success alone does not imply Xcode has it.
candidate=$(xcrun --find llvm-libtool-darwin 2>/dev/null || true)
if [[ "$candidate" == /* && -x "$candidate" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
fi

if command -v brew >/dev/null 2>&1; then
    for formula in llvm@20 llvm; do
        prefix=$(brew --prefix "$formula" 2>/dev/null || true)
        candidate="$prefix/bin/llvm-libtool-darwin"
        if [[ -n "$prefix" && -x "$candidate" && -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            exit 0
        fi
    done
fi

printf 'Missing llvm-libtool-darwin. Install Homebrew llvm@20 (brew install llvm@20), or set GHOSTTY_LLVM_LIBTOOL to its executable path.\n' >&2
exit 1
