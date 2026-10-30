#!/bin/bash
# Build only the pinned embedding SDK. Never launch Ghostty or Discobox.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
GHOSTTY_TAG=v1.2.3
GHOSTTY_REVISION=6d2dd585a5d87fa745d48188dd096ca6e63014d0
GHOSTTY_ZIG_VERSION=0.14.1
GHOSTTY_BUILD_ROOT="$REPO_ROOT/.build/ghostty"
GHOSTTY_SOURCE="$GHOSTTY_BUILD_ROOT/source"
GHOSTTY_SDK="$GHOSTTY_BUILD_ROOT/sdk/$GHOSTTY_REVISION"

case "${1:-}" in
    ""|--check) ;;
    *) printf 'Usage: bash scripts/build-ghostty-sdk.sh [--check]\n' >&2; exit 2 ;;
esac

failed=0
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The Ghostty macOS SDK requires macOS.\n' >&2
    failed=1
fi
if ! command -v zig >/dev/null 2>&1; then
    printf 'Missing Zig %s. Put that version on PATH before building the SDK.\n' "$GHOSTTY_ZIG_VERSION" >&2
    failed=1
elif [[ "$(zig version)" != "$GHOSTTY_ZIG_VERSION" ]]; then
    printf 'Expected Zig %s; found %s.\n' "$GHOSTTY_ZIG_VERSION" "$(zig version)" >&2
    failed=1
fi
if ! xcrun --find clang >/dev/null 2>&1 || ! xcrun --find xcodebuild >/dev/null 2>&1; then
    printf 'A full Xcode installation and selected developer directory are required.\n' >&2
    failed=1
fi
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    printf 'Missing Apple Metal Toolchain. Install it through Xcode, or run: xcodebuild -downloadComponent MetalToolchain\n' >&2
    failed=1
fi
if ! GHOSTTY_LLVM_LIBTOOL=$(bash scripts/find-llvm-libtool.sh); then
    failed=1
fi
if [[ -d "$GHOSTTY_SOURCE/.git" ]]; then
    if [[ "$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)" != "$GHOSTTY_REVISION" ]]; then
        printf 'Ghostty source is not at the pinned revision. It will not be overwritten.\n' >&2
        failed=1
    fi
else
    printf 'Source not cached: the build will need GitHub and Zig dependency downloads.\n'
fi
if [[ "${1:-}" == --check ]]; then
    printf 'Pinned SDK: %s (%s), Zig %s\n' "$GHOSTTY_TAG" "$GHOSTTY_REVISION" "$GHOSTTY_ZIG_VERSION"
    printf 'SDK destination: %s\n' "$GHOSTTY_SDK"
    exit "$failed"
fi
[[ "$failed" == 0 ]] || exit 1

mkdir -p "$GHOSTTY_BUILD_ROOT"
if [[ ! -e "$GHOSTTY_SOURCE" ]]; then
    # The public HTTPS fetch needs no user Git rewrites or credentials. This
    # environment override affects this command only, not the user's config.
    GIT_CONFIG_GLOBAL=/dev/null git clone --depth 1 --branch "$GHOSTTY_TAG" \
        https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SOURCE"
fi
if [[ "$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)" != "$GHOSTTY_REVISION" ]]; then
    printf 'Ghostty revision verification failed.\n' >&2
    exit 1
fi
if [[ -n "$(git -C "$GHOSTTY_SOURCE" status --porcelain --untracked-files=no)" ]]; then
    printf 'Ghostty source contains tracked modifications; refusing to label it as the pinned SDK.\n' >&2
    exit 1
fi
export ZIG_GLOBAL_CACHE_DIR="$GHOSTTY_BUILD_ROOT/global-cache"
export ZIG_LOCAL_CACHE_DIR="$GHOSTTY_BUILD_ROOT/local-cache"
export CLANG_MODULE_CACHE_PATH="$GHOSTTY_BUILD_ROOT/clang-cache"
bash scripts/fetch-ghostty-deps.sh
GHOSTTY_SDK_SHIMS="$(python3 scripts/prepare-ghostty-sdk-overlay.py)"
if [[ -n "$GHOSTTY_SDK_SHIMS" ]]; then
    printf 'Using a workspace-local libSystem SDK overlay for Zig 0.14.\n'
fi
# Apple's current libtool skips older Zig archive members with 2-byte padding.
# LLVM's Darwin archiver reads them and emits a correctly aligned combined .a.
GHOSTTY_TOOL_SHIMS="$GHOSTTY_BUILD_ROOT/tool-shims"
mkdir -p "$GHOSTTY_TOOL_SHIMS"
printf '#!/bin/bash\nexec %q "$@"\n' "$GHOSTTY_LLVM_LIBTOOL" > "$GHOSTTY_TOOL_SHIMS/libtool"
printf 'Using LLVM archiver: %s\n' "$GHOSTTY_LLVM_LIBTOOL"
chmod +x "$GHOSTTY_TOOL_SHIMS/libtool"
export PATH="$GHOSTTY_TOOL_SHIMS:$PATH"
(
    cd "$GHOSTTY_SOURCE"
    zig build -Doptimize=ReleaseFast -Dapp-runtime=none \
        -Demit-xcframework=true -Dxcframework-target=native \
        -Demit-macos-app=false -Demit-exe=false -Demit-docs=false -Demit-themes=false \
        -Dsentry=false -Di18n=false
)
test -f "$GHOSTTY_SOURCE/macos/GhosttyKit.xcframework/Info.plist"
test -d "$GHOSTTY_SOURCE/zig-out/share/ghostty"
mkdir -p "$GHOSTTY_SDK"
ditto "$GHOSTTY_SOURCE/macos/GhosttyKit.xcframework" "$GHOSTTY_SDK/GhosttyKit.xcframework"
ditto "$GHOSTTY_SOURCE/zig-out/share/ghostty" "$GHOSTTY_SDK/Resources/ghostty"
cp "$GHOSTTY_SOURCE/LICENSE" "$GHOSTTY_SDK/LICENSE"
printf '%s\n' "$GHOSTTY_REVISION" > "$GHOSTTY_SDK/REVISION"
plutil -lint "$GHOSTTY_SDK/GhosttyKit.xcframework/Info.plist"
# Verify the actual archive, since packaging can succeed after libtool silently
# skips incompatible archive members. This probe never initializes Ghostty.
GHOSTTY_SLICE="$GHOSTTY_SDK/GhosttyKit.xcframework/macos-$(uname -m)"
xcrun clang -I "$GHOSTTY_SLICE/Headers" Experiments/Ghostty/link-smoke.c \
    "$GHOSTTY_SLICE/libghostty-fat.a" -lc++ \
    -framework Carbon -framework CoreFoundation -framework CoreGraphics \
    -framework CoreText -framework CoreVideo -framework QuartzCore \
    -framework IOSurface -framework Metal -framework AppKit \
    -o "$GHOSTTY_BUILD_ROOT/link-smoke"
"$GHOSTTY_BUILD_ROOT/link-smoke"
printf 'Built native-architecture Ghostty SDK at %s\n' "$GHOSTTY_SDK"
printf 'No application was launched. Rebuild the desktop app to link this SDK.\n'
