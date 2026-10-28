# Building and developing Discobox for macOS

## Prerequisites

Use a Mac with:

- macOS 14 or newer.
- Full Xcode with Swift 6 and its Metal Toolchain component installed.
- Go 1.27.1 or newer on your PATH.
- Zig **0.14.1** on your PATH for the pinned Ghostty SDK.
- Python 3 for build helpers and script checks.

The scripts use your installed tools; they don’t install them for you.
If Metal is missing, install it through Xcode’s component settings.

## First build

Run these commands from the root of this repository. Access to the Discobox
source repository is required:

```sh
git clone https://github.com/discobox-ai/discobox.git discobox
git -C discobox checkout d61a7f405389fcc0dda68c5689397aec3a085d9e
make ghostty
make build
open dist/Discobox.app
```

If `discobox/` already exists, check its revision instead of cloning again.
The app uses this source for its companion client; building does not start a
Discobox server. The checkout is excluded from this repository’s commits.

`make ghostty` builds the pinned Ghostty v1.2.3 embedding SDK. It is needed before
SwiftPM or Xcode can build the app. Check its prerequisites without building with:

```sh
bash scripts/build-ghostty-sdk.sh --check
```

After the first build, use `make build`. The app is written to
`dist/Discobox.app`; quit and reopen it to use a new build. Dependencies and tool
caches live under `.build/`.

## Make targets

| Target | Purpose |
| --- | --- |
| `make build` | Build and ad-hoc sign the app bundle |
| `make test` | Run Swift tests, Go race tests, and Go vet |
| `make lint` | Check Swift compiler warnings, Go formatting, script syntax, plist, and diff whitespace |
| `make vet` | Run Go static analysis alone |
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

For an additional interactive-session check, run the demo UI smoke test:

```sh
dist/Discobox.app/Contents/MacOS/DiscoboxDesktop \
  --dialog-smoke -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
```

This opens an isolated demo window, checks dialogs and inspector behavior, and
exits with a pass/fail result. It requires a logged-in macOS desktop session.

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
