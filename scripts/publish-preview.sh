#!/bin/bash
set -euo pipefail

: "${GH_REPO:?Set GH_REPO to the destination owner/repository}"
: "${RELEASE_TAG:?Set RELEASE_TAG to an existing version tag}"
: "${RELEASE_COMMIT:?Set RELEASE_COMMIT to the built commit}"
[[ "$RELEASE_TAG" =~ ^v[0-9][A-Za-z0-9._+-]*$ ]] || { printf 'Expected a version tag beginning with v and a digit.\n' >&2; exit 1; }
[[ "$RELEASE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { printf 'Expected the built commit SHA.\n' >&2; exit 1; }

archive=${1:-dist/Discobox-macos-arm64.zip}
test -s "$archive"
unzip -tq "$archive"
unzip -Z1 "$archive" | awk '
    $0 == "Discobox.app/Contents/Info.plist" { info = 1 }
    $0 == "Discobox.app/Contents/MacOS/DiscoboxDesktop" { executable = 1 }
    END { exit !(info && executable) }
'
(
    cd "$(dirname "$archive")"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)

# Keep an existing release's notes, title and publication status. Re-running a
# successful tag build replaces only these two assets, not unrelated uploads.
if gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null; then
    gh release upload "$RELEASE_TAG" "$archive" "$archive.sha256" --repo "$GH_REPO" --clobber
else
    notes=$(mktemp)
    trap 'rm -f "$notes"' EXIT
    cat > "$notes" <<EOF
Preview software: development is moving fast, and things will break.

Download Discobox-macos-arm64.zip for Apple Silicon Macs running macOS 14 or newer.
Install and set up Discobox first: https://github.com/discobox-ai/discobox#getting-started

This app has no Apple Developer ID signature and is not notarized. Installation
and first-launch instructions: https://github.com/$GH_REPO/blob/$RELEASE_TAG/README.md

Built from commit $RELEASE_COMMIT. The .sha256 asset contains the app ZIP checksum.
EOF
    gh release create "$RELEASE_TAG" "$archive" "$archive.sha256" --repo "$GH_REPO" \
        --verify-tag --prerelease --latest=false --title "Discobox $RELEASE_TAG preview" --notes-file "$notes"
fi
