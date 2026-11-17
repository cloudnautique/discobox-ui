# Approval review state and persistent read companion

Investigated against `8bf38b8` plus the local native-window/control changes.
These are separate follow-ups; neither implementation is included in that UI change.

## Review finding 7: approval lifecycle still belongs to views

Confirmed. `ApprovalStore` owns the inbox, validation, submission and receipt
publication, but the three review forms still own their drafts and lifecycles:

- `LegacyApprovalSheet` in `ApprovalViews.swift`: credential selection, duration,
  trust consent, new-token fields, connection, loading/busy/closed flags and receipt.
- `ScopedCredentialApprovalView`: selected credential, use/delegation decisions,
  review fingerprint, request token, loading/busy/closed/reload flags and receipt.
- `ConsentApprovalView`: replacement token, reviewed consent, connection,
  busy/closed flags and receipt.

There is a concrete difference beyond code organization. Scoped submission passes
a `proceed` closure to `ApprovalStore.answer`, preventing transmission if the user
closes during validation. Legacy and consent submission omit it and use the default
`true`. Legacy credential creation also lacks the scoped form's post-validation
`closed` check. Once transmission has begun, all forms must treat an interrupted
response as potentially committed; closing cannot imply that access was revoked.
Existing connection-generation checks protect against retargeting. This finding
does not establish that those checks are bypassed.

### Implementation

1. Give each format an `@MainActor @Observable` review model in Core, injected with
   the approval and credential services and an immutable request/connection scope.
   Keep protocol-specific draft types separate. Do not move all forms into one
   large switch-based model or add them to the long-lived inbox store.
2. Model the transition from loading to review, validation, transmission and
   receipt/uncertain failure explicitly. Track read-task identity and review
   fingerprint in the model. Freeze the decision payload when submission starts.
3. Make `close()` withdraw pending reads and validation, clear draft secrets, and
   prevent any not-yet-sent mutation. After transmission, retain the operation
   independently until it records a receipt or uncertain failure; never replay it
   automatically. Publish that result to the originating request's owner even if
   the sheet has closed. Clear token copies when the operation finishes.
4. Views retain only presentation state: disclosures, focus and scroll geometry.
   They bind to one model, invoke actions and dismiss on a model outcome. Moving
   the model reference into view `@State` is expected; the business state no longer
   lives in many unrelated property wrappers.
5. Add deterministic tests for closure during delayed metadata/preflight, closure
   after send, request replacement/withdrawal, host reconnection, draft changes
   during preview, duplicate submission and uncertain failure. Existing payload,
   scope and receipt tests stay in place. Run approval workflow, queue, conflict,
   dialog-receipt and consent fixtures on macOS after wiring the views.

### Status: implemented

Implemented as `ApprovalReviewLifecycle` plus `LegacyApprovalReview`,
`BindingApprovalReview` and `ConsentApprovalReview` in Core, with the three forms
bound to them. Legacy and consent decisions now withdraw when closed during
validation, and legacy credential creation checks closure after validation. After
an unconfirmed decision, legacy and consent forms require Check again (a fresh read)
instead of re-enabling decisions. The step 5 cases are covered by
`ApprovalReviewTests` on Linux; the approval duration fixture (run by
`--approval-workflow-smoke`) adds a close-during-validation mode. The views were
rewired without a macOS build: `--approval-workflow-smoke` (duration, queue,
modern, dialog-receipt and upstream/consent panels), `--approval-queue-smoke`,
`--binding-conflict-smoke`, `--agent-activity-smoke` and `--command-smoke` (the
inbox now has one window-level owner) still need to run on macOS.

## Review finding 5: bounded helper processes per inventory refresh

**Status: implemented** (persistent read-only companion; see ARCHITECTURE.md,
"Components"). Every `read` operation goes to one `--read-server` helper per
connection generation; writes, shells and transfers keep the one-shot path.
The Go side (`Companion/internal/readserver`, `bridge.Reader`) and the Swift
side (`ReadCompanion`, `CompanionClient`) are covered by tests for framing,
out-of-order replies, cancellation beside a running read, EOF inside a frame,
oversized/invalid frames, permission refusal, version mismatch, helper death
and restart, reconnect isolation, and write flags. Bodies travel as raw bytes
after a JSON header instead of base64 (review P4), for JSON and non-JSON alike,
so the app decodes each body once.

**Still to do on a Mac:** measure helper launches, refresh latency and CPU
before/after on a local socket and over Iroh (e.g. count `discobox-desktop-bridge`
launches during a few minutes of polling with a box selected), and confirm with
a Desktop build that termination (`CompanionClient.cancelAllRequests`) and
disconnect leave no read helper running. Inventory batching remains unevaluated.

Confirmed with a qualification: `ConnectionSession.refresh()` reads `.sandboxes`,
then `BoxSelectionStore.refreshDetails()` reads `.execs` and `.services` concurrently
when a box is selected. `CompanionClient.perform()` creates a `ProcessRequest` for
each operation. With no selected box, the latter two calls do not happen. Approval,
resource and usage polling are separate operations and can add more helpers.

The current Iroh proxy is already persistent/shared by the client. It is the
bounded request helper which starts repeatedly. `runManaged` intentionally accepts
exactly one JSON request, requires EOF, configures that operation's permission and
deadline, and closes its HTTP connection pool afterward. This provides useful
cancellation and permission isolation at the expense of process and connection
reuse. The polling-cadence changes reduce frequency but do not change this design.
The process count is established from the code; the actual CPU/latency cost has
not yet been measured, so it should not be presented as the cause of a freeze.

### Implementation

1. Start with a persistent **read-only** companion owned by one connection
   generation. Reuse its HTTP transport and, for Iroh, the existing proxy endpoint.
   Keep writes/shell launches on their current one-shot, permission-scoped path.
   Do not start a permanently `--allow-manage` helper for routine polling.
2. Define a versioned framed request/response envelope with a separate correlation
   ID. The existing `requestID` identifies an approval request; it must not be
   repurposed as a transport sequence ID. Bound frame size, queued bytes and
   concurrent operations; reject unknown operations and inappropriate permissions.
3. Support per-request deadline/cancellation without killing unrelated reads.
   On helper death, fail all outstanding continuations once. A new generation may
   restart for fresh reads; old IDs/responses cannot cross a reconnect. Ensure pipe
   reads/writes remain off the main actor and Swift's cooperative executor.
4. Keep terminal and service results independent. A single all-or-nothing inventory
   response would reintroduce the bug where slow service discovery delays the
   usable terminal. Multiplexed responses can reduce helper launches without
   combining their completion or failure domains.
5. Test out-of-order replies, cancellation while another read proceeds, EOF during
   a frame, oversized/invalid data, helper death/restart, disconnected owners,
   version mismatch, and permission rejection. Measure process launches, refresh
   latency and CPU before/after on local and Iroh connections.

Inventory batching can be evaluated after the persistent read transport works.
It is not required to obtain the main process-reuse benefit, and should not weaken
partial-result publication or the existing request-scope checks.
