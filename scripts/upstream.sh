#!/bin/bash
# The Discobox source checkout at discobox/ (gitignored) supplies the
# companion's upstream packages and the brand tokens. Its revision is pinned in
# UPSTREAM_REVISION, the only place it is recorded; builds, tests, lint and CI
# all read it from there.
#
#   upstream.sh revision  print the pinned revision
#   upstream.sh check     fail unless discobox/ is a clean checkout of it
#   upstream.sh sync      clone or fetch discobox/ and check it out (make upstream)
#
# DISCOBOX_UPSTREAM_UNPINNED=1 downgrades a failed check to a warning, for
# deliberately building against an upstream change before moving the pin.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checkout="$root/discobox"
source_url="${DISCOBOX_SOURCE_URL:-https://github.com/discobox-ai/discobox.git}"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

pinned() {
    local revision
    revision=$(tr -d '[:space:]' <"$root/UPSTREAM_REVISION") || fail "UPSTREAM_REVISION is missing"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "UPSTREAM_REVISION must hold one full 40-character commit hash"
    printf '%s\n' "$revision"
}

mismatch() {
    if [[ "${DISCOBOX_UPSTREAM_UNPINNED:-}" == 1 ]]; then
        printf 'warning: %s (continuing: DISCOBOX_UPSTREAM_UNPINNED=1)\n' "$1" >&2
        return
    fi
    fail "$1. Run 'make upstream' to check out the pinned revision, or set DISCOBOX_UPSTREAM_UNPINNED=1 to build against it deliberately."
}

check() {
    local revision actual
    revision=$(pinned)
    if [[ ! -e "$checkout" ]]; then
        fail "discobox/ is missing. Run 'make upstream' to clone the Discobox source at the pinned revision $revision."
    fi
    actual=$(git -C "$checkout" rev-parse --verify --quiet 'HEAD^{commit}') ||
        fail "discobox/ is not a Git checkout. Remove it and run 'make upstream'."
    if [[ "$actual" != "$revision" ]]; then
        mismatch "discobox/ is at $actual but UPSTREAM_REVISION pins $revision"
    elif [[ -n "$(git --no-optional-locks -C "$checkout" status --porcelain --untracked-files=no)" ]]; then
        mismatch "discobox/ has local changes on top of the pinned revision $revision"
    fi
}

sync() {
    local revision
    revision=$(pinned)
    if [[ ! -e "$checkout" ]]; then
        git clone --no-checkout "$source_url" "$checkout"
    fi
    if ! git -C "$checkout" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$checkout" fetch origin "$revision" || git -C "$checkout" fetch origin
    fi
    # A detached checkout refuses to overwrite local changes instead of losing them.
    git -C "$checkout" checkout --quiet --detach "$revision"
    check
    printf 'discobox/ is at the pinned revision %s.\n' "$revision"
}

case "${1:-}" in
    revision) pinned ;;
    check) check ;;
    sync) sync ;;
    *)
        printf 'Usage: %s {revision|check|sync}\n' "$0" >&2
        exit 2
        ;;
esac
