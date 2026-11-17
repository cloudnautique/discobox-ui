# Building and developing Discobox for macOS

## Prerequisites

Use a Mac with:

- macOS 14 or newer.
- Full Xcode with Swift 6 and its Metal Toolchain component installed.
- Go 1.27.1 or newer on your PATH.
- Zig **0.14.1** on your PATH for the pinned Ghostty SDK.
- LLVM's `llvm-libtool-darwin` archiver (`brew install llvm@20`).
- Python 3 for build helpers and script checks.

The scripts use your installed tools; they don’t install them for you.
If Metal is missing, install it through Xcode’s component settings.
The Ghostty build discovers the LLVM archiver on PATH, through Xcode, or in
Homebrew's `llvm@20`/`llvm` installations. Set `GHOSTTY_LLVM_LIBTOOL` to an absolute
executable path to choose it explicitly; Xcode does not always include this tool.

## First build

Run these commands from the root of this repository. Access to the Discobox
source repository is required:

```sh
make upstream
make ghostty
make build
open dist/Discobox.app
```

`make upstream` clones the Discobox source into `discobox/`, or fetches into an
existing checkout, and checks out the revision pinned in `UPSTREAM_REVISION`.
That file is the only place the revision is recorded: `make build`, `make test`,
`make lint`, `make vet`, `make smoke` and CI fail early, naming both revisions,
when `discobox/` is missing, at another commit, or has local changes. To try an
upstream change before moving the pin, set `DISCOBOX_UPSTREAM_UNPINNED=1`, which
turns that failure into a warning. Set `DISCOBOX_SOURCE_URL` to clone from a
mirror. To move the pin, edit `UPSTREAM_REVISION` and run `make upstream`.

The app uses this source for its companion client; building does not start a
Discobox server. The checkout is excluded from this repository’s commits.

`make ghostty` builds the pinned Ghostty v1.2.3 embedding SDK. It is needed before
SwiftPM or Xcode can build the app. Check its prerequisites without building with:

```sh
bash scripts/build-ghostty-sdk.sh --check
```

Ghostty is checked out from `ghostty-org/ghostty` on GitHub. Its pinned `zg`
dependency is prefetched from the `pfgithub/zg` GitHub mirror at the original
commit, with its Zig package hash checked against the upstream manifest. This
avoids Zig 0.14's failing Codeberg Git fetch without changing dependency contents.

The SDK build applies `patches/ghostty-*.patch` to recognize Discobox URLs and
release mouse reporting after a child exits, then reverses those patches in the
source checkout. The SDK records their combined digest, which packaging verifies
to avoid shipping an older cached terminal. Navigation and connection state are
handled by the app. To check links and recovery using offline terminal fixtures
(requires an unlocked desktop):

```sh
make smoke
.build/DiscoboxSmoke.app/Contents/MacOS/DiscoboxSmoke --box-link-smoke
.build/DiscoboxSmoke.app/Contents/MacOS/DiscoboxSmoke --terminal-recovery-smoke
```

The bridge reports attachment state through a private, nonblocking FIFO, separate
from terminal bytes. Reconnect status never depends on parsing agent output and
adds no polling requests. Temporary metadata failures remain inconclusive; only
confirmed terminal/box states end the resumable stream. Local text remains
copyable during disconnection, and the last output is retained in memory across
reattachment (up to 8 MiB per terminal, cleared when the box/session closes).

After the first build, use `make build`. The app is written to
`dist/Discobox.app`; quit and reopen it to use a new build. Dependencies and tool
caches live under `.build/`.

## Make targets

| Target | Purpose |
| --- | --- |
| `make upstream` | Clone or update `discobox/` to the pinned `UPSTREAM_REVISION` |
| `make build` | Build and ad-hoc sign the app bundle |
| `make test` | Run Swift tests, Go race tests, and Go vet |
| `make lint` | Check Swift compiler warnings, Go formatting, script syntax, plist, and diff whitespace |
| `make vet` | Run Go static analysis alone |
| `make brand-tokens` | Regenerate the native palette after updating pinned backend brand tokens |
| `make fmt-go` | Format companion Go source and tests |
| `make verify` | Verify the built app’s signature and plist |
| `make ci` | Run lint → test → build → verify |
| `make ghostty` | Build the pinned Ghostty SDK |
| `make help` | List targets |

Lint does not rewrite source. Swift checks use compiler warnings as errors,
without imposing a new formatting style. The original `scripts/build-app.sh` and
`scripts/test.sh` entry points still work.

## Tests and CI

`make ci` needs the same macOS tools, Discobox checkout, and Ghostty SDK as a local
build. It runs sequentially, including with `make -j`, because targets share build
output. Dependency downloads may require network access.

Tests use synthetic data, fixture executables, and temporary local HTTP/WebSocket
and Iroh servers. They do not connect to your running Discobox backend. CI does
not launch the GUI.

### GitHub Actions preview builds

The **Build preview** workflow runs on pushed tags matching `v*` (for example,
`v0.1.0-preview.1`) and through **Run workflow**. It uses an Apple Silicon macOS 26
runner with Xcode 26.6, installs the Go version in `Companion/go.mod` and
checksum-verified Zig 0.14.1, selects Homebrew LLVM 20's Darwin archiver, and builds
the pinned Ghostty SDK when uncached.
It then runs `make ci` and uploads `Discobox-macos-arm64.zip` as an Actions artifact
for 30 days. The run summary contains the commit and ZIP checksum.

For version tags, a separate publishing job downloads that exact ZIP, verifies
its artifact digest, and attaches it and a `.sha256` checksum to the tag's GitHub
Release. If the release does not exist, it creates a prerelease with installation
notes. Existing release notes, titles, and publication status are preserved;
reruns replace only the app ZIP and its checksum. Build jobs keep read-only
repository access; only the publishing job receives `contents: write`.

Manual runs on branches produce Actions artifacts only. A manual run on a
version tag also publishes its release assets. The app remains ad-hoc signed
and not notarized.

If the Discobox source or its `github.com/discobox-ai/*` dependencies are private,
add a repository Actions secret named **DISCOBOX_SOURCE_TOKEN** with read-only
access to those repositories. The normal workflow token cannot read another
private repository. No Apple signing credentials are required for preview builds.

Pushing a tag triggers a build; making a local tag alone does not. For example,
after committing and pushing the intended app version:

```sh
git tag v0.1.0-preview.1
git push origin v0.1.0-preview.1
```

The workflow checks out the exact tag's app source and the Discobox source at
the revision in `UPSTREAM_REVISION`.
Update the runner/Xcode selection and cache keys together when changing toolchains.

For an additional interactive-session check, run the demo UI smoke test:

```sh
make smoke
.build/DiscoboxSmoke.app/Contents/MacOS/DiscoboxSmoke \
  --dialog-smoke -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
```

The separate debug executable imports the same `DiscoboxUI` module used by the
release app and mounts `ConnectedWorkspace` with fixture clients. It checks dialogs
and inspector behavior, then exits with a pass/fail result. It requires an unlocked,
logged-in macOS desktop. Run it with `--help` to list checks. Smoke flags are not
handled by the shipping app. The fixture bundle has its own identifier and no box
URL registration; it is not copied into `dist` or release archives.

`swift build --product DiscoboxDesktop --configuration release` builds only the
shipping dependency graph. `make verify` also checks its binary for leaked smoke
runners/flags. The smoke target requires a debug build for `@testable` access to UI
internals; a release build of that target only prints the debug build instruction.

`--native-window-smoke` uses the production auxiliary `WindowGroup` scenes to
check window reuse, independent ownership, console close cancellation/confirmation,
and cleanup on disconnect or before a window mounts. It also checks native alert
defaults without clipboard or credential access. `--recovery-smoke` checks that
warnings reserve space above the native navigation split in both appearances.
These checks need WindowServer access; launching inside a sandbox that blocks
application registration can abort before any fixture code runs.

## Xcode

After `make build`, open `Package.swift` in Xcode and select the executable target.
Set these environment variables in its run scheme:

- `DISCOBOX_DESKTOP_BRIDGE`: the absolute path to `.build/discobox-desktop-bridge`.
- `GHOSTTY_RESOURCES_DIR`: the absolute path to the built Ghostty SDK’s
  `Resources/ghostty` directory, beneath `.build/ghostty/sdk/`.

The packaged app finds its companion and resources automatically.

## Distribution

The current build is ad-hoc signed for local development. Developer ID signing,
notarization, and complete third-party notices remain release work. The packaged
app includes Ghostty’s license and the Iroh binding’s upstream README.

For implementation details, see [Architecture](../ARCHITECTURE.md).

The release bundles JetBrains Mono Regular v2.304 (OFL-1.1) for brand headings.
The original font, license, source and checksum are in `Resources/Fonts/`.
It is registered for the app process only and is never installed system-wide.
`make lint` checks its checksum and the palette generated from the backend's
canonical brand tokens.
