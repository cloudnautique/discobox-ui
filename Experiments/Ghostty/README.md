# Ghostty embedding spike

The embedding SDK and live desktop integration are implemented. This document
records the pinned SDK recipe and its toolchain workarounds.

## Pinned input

- Ghostty release `v1.2.3`, commit `6d2dd585a5d87fa745d48188dd096ca6e63014d0`.
- Zig `0.14.1`, full Xcode, and its Metal Toolchain component.
- The native macOS `GhosttyKit.xcframework`, accompanying Ghostty resources,
  and license. Native architecture first; universal packaging follows after the
  embedding spike is validated.

The release's full surface API is experimental. Pinning avoids silently compiling
against a changed ABI; it does not make the API stable. This pin is a baseline for
the spike, not a claim that it is the newest Ghostty release.

## Build/preflight

```sh
bash scripts/build-ghostty-sdk.sh --check
bash scripts/build-ghostty-sdk.sh
```

Preflight reads local tool availability and cached source revision only. The build
fetches the pinned public source and its dependencies, verifies the commit, and
builds the XCFramework without building/launching the Ghostty app. Everything
stays under `.build/ghostty`. It neither installs a toolchain nor reads/modifies
the installed Ghostty app or the running Discobox server.

The native arm64 SDK built successfully on 2026-10-26 after installing Metal
through Xcode's GUI (the command-line component download failed). The build now
compiles and runs `link-smoke.c` against the packaged archive; it reports
`Ghostty 1.2.3` without initializing the runtime or spawning a terminal.
The desktop app now links this SDK and packages its resources. The offline
AppKit/PTY smoke check validates output, input, resize, alternate screen, and
teardown. Live-server testing remains intentionally excluded.

Three local build fixes were necessary:

- The new macOS SDK's libSystem stub omits the arm64 target understood by Zig
  0.14. `prepare-ghostty-sdk-overlay.py` builds a symlink overlay under `.build`,
  substituting Zig's bundled libSystem stub while retaining the real SDK headers
  and frameworks. A build-only xcrun shim points Zig there. Installed SDK and Zig
  files remain untouched. Both the build-runner and framework link now pass.
- Apple's archiver skipped some Zig archive members because of their alignment.
  A workspace-local `libtool` shim uses Xcode's `llvm-libtool-darwin` to combine
  them correctly. The old archive's Zig cache manifest was invalidated once;
  subsequent cached builds also pass the link probe.
- The pinned optional theme archive returns HTTP 404. Themes are disabled for the
  spike; the core engine and required resources remain enabled.

## Integrated executable slice

- `Sources/DiscoboxDesktop/GhosttyTerminal.swift` owns the runtime, surface,
  AppKit input adapter, and connection-scoped session store.
- `Companion/attach.go` transports raw PTY bytes over the existing resumable
  WebSocket protocol. Local process termination detaches without remote signals.
- `--demo` uses a synthetic child; `--terminal-smoke` runs the offline integration
  checks and exits. The fixture server tests exercise the live transport path.
- Live terminal screen polling and the input checkbox/composer are removed.
  Saved screens remain available for non-live terminals.

References used for the build recipe:

- [Pinned release](https://github.com/ghostty-org/ghostty/releases/tag/v1.2.3)
- [Dependency/toolchain manifest](https://github.com/ghostty-org/ghostty/blob/v1.2.3/build.zig.zon)
- [Build options](https://github.com/ghostty-org/ghostty/blob/v1.2.3/src/build/Config.zig)
- [XCFramework builder](https://github.com/ghostty-org/ghostty/blob/v1.2.3/src/build/GhosttyXCFramework.zig)
