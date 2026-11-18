# Terminal sizing when returning to a box

**Status.** Local implementation reconciles retained child frames on layout and
rebind. The native smoke checks the Ghostty grid and local fixture PTY. Live
remote and simultaneous-viewer reproduction are still open. Separate review from
[polling and recovery work](POLLING-AND-EVENTS-PLAN.md).

**Baseline:** UI `2a9b024`. Primary implementation boundary:
`Sources/DiscoboxDesktop/GhosttyTerminal.swift`; native terminal/command smokes.

Reported behavior: after switching away and back, output wraps in a narrow area
inside a wide pane until the user manually resizes. Desired behavior is automatic
geometry reconciliation after the selected pane has laid out, with no window
nudge, terminal restart or dummy input.

The current container sizes the retained view when it reparents it; `mount()`
returns early for an already-mounted view. Ghostty's resize path also skips an
unchanged pixel size. These are investigation points, not a reproduced diagnosis:
the stale dimensions could be in the container, Ghostty, the local PTY or the
remote PTY, including interference from another viewer of the same exec.

- Trace container/child bounds, backing scale, Ghostty rows/columns, local PTY
  dimensions and the last outbound resize on selection/remount. Log dimensions
  and scoped IDs only. Reproduce with retained and evicted sessions.
- Add a coalesced presentation activation/layout hook. Reconcile the child to
  its current owning container even when no reparent occurred, then synchronize
  Ghostty after a valid layout. Ignore detached/zero-sized containers and reject
  deferred work from an old selection/owner. React to layout completion rather
  than a fixed sleep or an artificial shrink/grow.
- Carry the resulting dimensions through the existing PTY/resize-frame path.
  If reproduction shows local dimensions are right but the remote PTY is stale,
  explicitly reannounce current rows/columns once on activation through the
  existing attachment. Do not reconnect or add a guest HTTP read to force sizing.
  Verify resize ownership with simultaneous viewers before choosing a reassertion
  policy; do not create competing periodic resize loops.
- Keep focus separate. A user selecting a terminal can focus it once mounted;
  layout changes must not steal focus from search, menus, dialogs or another pane.
  Preserve scrollback, selection and the user's split proportions.

Native regression: A → B → A without resizing the window, with different shell
splits/sidebar widths, a cached container, an evicted surface, rapid switches and
backing-scale changes. Assert native bounds, Ghostty grid and fixture PTY size
agree; a screenshot alone is insufficient. Test local and Iroh attachments and
two viewers of one exec. A warm return must not restart its helper or add HTTP
metadata requests. This fix can ship early, independently of SSE and transport.

Deliver as a focused presentation fix with its own native regression evidence.
It neither blocks nor depends on the guest-load changes.
