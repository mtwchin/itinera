# Sprint D2 — Private Offline Identity

**Date:** July 13, 2026
**Baseline:** `f7affa3` (`codex/sprint-1-integration`)
**Branch:** `codex/d2-private-offline-identity`
**Status:** Implemented and independently verified; release remains gated on
the Sprint P2 backend dependency recorded below.

## Outcome and boundaries

No traveler may see, publish, submit, or mutate another server principal's
private device state while identity is restored, linked, refreshed, deleted,
or switched. Identity is a prerequisite for private UI, storage, networking,
WidgetKit, Live Activities, local notifications, and private deep links.

This sprint changes only the iOS client and its documentation. Existing
authentication responses provide the server-issued `user_id` used by the new
credential contract. Backend API changes, account/library merging, cloud sync,
queued offline server mutations, APNs delivery, and recovery of ambiguous
legacy device data are explicitly out of scope. Retry-safe convergence after a
lost successful `DELETE /auth/me` response is an explicit integration
dependency on Sprint P2's signed-subject, retry-safe deletion contract. D2
retains the original credentials and journal and fails closed until that
backend contract confirms completion; D2 must not ship against an older
backend that treats a repeated deletion as an unauthenticated new identity.
The integrated request order is exact: use normal signed-current
authentication first; only an actually expired access token may use P2's
deletion-token fallback. P2 returns `204` only for a validly signed subject
that is already absent, and returns `401` for an expired token whose subject
still exists. Invalid signature, issuer, audience, token type, or required
claims always fail closed.

Offline means that a principal established by this release can reopen that
principal's protected device copy without a network connection. It does not
mean the copy is synchronized, recoverable on another device, or current with
the server.

## Audit finding

The accepted baseline has one global copy of every private store and renders it
before authentication is lazy-bootstrapped. It can also replay an unscoped
submission before it knows who owns it. A refresh rejection silently creates a
new guest, and Apple-link `409` silently signs in to another Apple library while
the previous library remains on screen. A delayed old request can then be
retried with the new account's bearer token. Widget, Live Activity, local
notification, and deep-link contracts contain no principal scope.

Scoped filenames alone cannot repair those races. D2 therefore introduces one
identity coordinator whose monotonically increasing epoch is the barrier for
credentials, API requests, local stores, published UI, and external surfaces.

## Trust and identity model

- The only trusted principal identifier is `user_id` decoded from a successful
  server authentication response or the same value previously persisted with
  credentials in Keychain by this release.
- JWT payloads are never decoded to infer identity.
- Raw `user_id` remains inside the credential/session boundary. It is never
  used in a file name, `UserDefaults` key, App Group key, URL, notification,
  log, accessibility string, or UI.
- `PrincipalScope` is the full lowercase SHA-256 digest of the UTF-8 bytes of
  the domain-separated, lowercase, hyphenated UUID text:
  `itinera-principal-scope-v1\0<lowercase hyphenated UUID>`. The fixed
  64-character digest is opaque, deterministic, and collision-resistant; it is
  an ownership label, not an authentication secret. Fixed test vectors lock
  that representation.
- Each private operation receives an immutable lease containing scope, epoch,
  and a random presentation-session UUID generated for that establishment. It
  checks the lease after every suspension point and again before it saves
  credentials, writes a store, publishes UI, schedules a notification, updates
  an Activity, or handles navigation.
- Ordinary server work also captures a short-lived readiness generation bound
  to that exact identity lease. Recovery Required retains it only as a paused
  boundary classifier and rejects it for requests, retries, credential writes,
  and queue commits. Starting explicit recovery retires even that old boundary
  authority and creates an exact recovery lease; only a verified same-principal
  refresh under that lease can mint a replacement ready generation. This keeps
  a delayed R1 response from relatching or tearing down recovered R2.
- Advancing the epoch invalidates every older lease. SwiftUI task cancellation
  is a useful optimization, not the privacy control.
- External surfaces persist the opaque scope and presentation-session UUID.
  The UUID prevents delayed A-session work from being accepted after A→B→A,
  and unlike a process-local numeric epoch it cannot collide after relaunch.
  Private file paths remain keyed only by the stable principal digest.

## Identity states and transitions

| State | Private presentation | Allowed behavior | Exit |
|---|---|---|---|
| Restoring | A calm full-screen privacy/loading state; no tabs or private titles underneath | Inspect Keychain, quarantine unscoped legacy state, and establish a lease | Ready or blocked |
| Ready — established | Private tree keyed by the scope and epoch | Read/write only that scope; network requests require the matching lease | Restoring, switching, deleting, or recovery required |
| Ready — offline established | The matching protected offline library with literal offline copy | Local reads and local progress/draft writes for that scope; no claim of sync; server calls may fail normally | Network recovery or an explicit transition |
| Recovery required | Existing scoped offline state may remain readable, but server submission/mutation is stopped with a calm explanation | Retry the same principal or explicitly start a replacement private session through the coordinator | Ready or switching |
| Apple conflict | The current library remains visible but linking controls are busy; a dialog states that libraries stay separate | Keep this library, or explicitly confirm a switch using only the ephemeral Apple token | Ready or switching |
| Switching | Full-screen privacy curtain; old private tree has been destroyed | Invalidate epoch, cancel auth/private work, unpublish old surfaces, obtain/commit target credentials, bind and stage target stores | Ready for the target or blocked |
| Clearing downloads | The current Settings tree remains covered while local removal starts; after the lease rotates, a full-screen same-principal progress state replaces it | Remove only this principal's completed-trip and progress files, tear down old surfaces, and bind fresh store actors for the same principal; server copies are not deleted | Ready for the same principal or blocked |
| Deleting/signing out | Full-screen privacy curtain | Invalidate, unpublish, independently attempt every scoped cleanup, then clear credentials | New guest bootstrap or blocked |
| Creating replacement session | Full-screen progress state with no prior private content | After durable cleanup and journal clearing, create and establish a separate guest principal; never restore or merge the deleted/signed-out library | New guest Ready or blocked |
| Cleanup required | Full-screen privacy curtain with the durable intent and stage named; no private session exists | Resume the same journaled account deletion or local sign-out cleanup; ordinary bootstrap is forbidden | Resuming cleanup or blocked |
| Cleanup blocked | Full-screen privacy curtain with the retained intent and exact reason; no private session exists | Preserve the journal and evidence; offer support/re-verification rather than a misleading network retry | Verified recovery flow only |
| Resuming cleanup | Full-screen progress state with no private session | Re-run the retained stage idempotently before credential restore, guest creation, quarantine, or private render | New guest Ready or cleanup required |
| Blocked | No private tabs; accessible error text and a 54-point Retry control | Retry identity establishment only | Restoring |

The established content root is keyed by identity epoch/scope. A transition
therefore destroys navigation stacks, sheets, alerts, editors, invitation
state, and view-local trip/tool models before another principal can render.

### Launch and relaunch

1. The root starts in Restoring and publishes no private arrays.
2. A new-format credential with a valid persisted server `user_id` establishes
   its scope without requiring token refresh. Its scoped offline store can open
   in airplane mode even when the access token is expired.
3. A legacy credential record safely decodes with `user_id == nil`, but does
   not establish identity. The coordinator must obtain `user_id` from the
   refresh endpoint while the privacy curtain remains. Offline legacy launch
   is blocked rather than guessed.
4. Missing credentials require online guest creation. Private UI is not shown
   until the response's required `user_id` is persisted and scoped stores are
   staged.
5. Invalid Keychain data fails closed. It may be cleared only inside this
   bootstrap transition, after external/unscoped state is unpublished.

### Refresh and request boundary

- Every auth response must contain a valid `user_id`.
- Normal refresh may rotate tokens only when its `user_id`, captured scope, and
  epoch still match the request.
- A different refresh `user_id` is an identity-integrity failure. Credentials
  are not saved and the original request is never retried.
- A refresh `401` returns a typed identity-recovery-required error. It never
  clears credentials or silently creates a guest from an ordinary library,
  delete, generation, or mutation request.
- Only the coordinator may recover by advancing the epoch, removing the old UI
  and external surfaces, then clearing credentials, creating a guest, binding
  its stores, and publishing. Until that explicit sequence, the known
  principal's scoped offline copy remains isolated and no pending submission
  is replayed.
- A request created under A can be retried only with refreshed A credentials.
  A delayed A response after A→B or rapid A→B→A fails its old epoch and
  presentation session even though the digest happens to be A again.
- Request dispatch, refresh-task sharing, auth-response acceptance, Keychain
  mutation, terminal-401 latching, retry dispatch, and final publication all
  require the same readiness generation. A paused R1 may classify a sibling
  R1 integrity failure, but beginning recovery retires R1 boundary authority
  before any Keychain or network suspension; its recovery lease alone can
  mint R2.
- Every view-local result performs one last exact initiating-session check
  immediately before synchronous state publication or side effect. Rebuilding
  the keyed root is a second barrier, never a substitute for this check.

## Apple linking and explicit account switching

The Apple identity token exists only in the authorization callback, an
in-memory task, and the temporary confirmation state. It is never logged or
persisted and is discarded on cancel, completion, view destruction, or error.

1. `POST /auth/apple/link` success must return the current `user_id`. The
   client rotates credentials within the current epoch and reports “This
   library is connected to Apple.” A mismatched successful response fails
   closed.
2. Only `409` with `apple_account_exists` becomes a typed switch-available
   result. It does not call `/auth/apple` and does not replace credentials.
3. The dialog offers **Keep This Library** and **Switch Library**. It says the
   Apple account already has a separate library, trips/drafts/progress are not
   merged or cloud-synced, and switching will hide the current library.
4. Cancel keeps the original credentials, scope, stores, and presentation.
5. Confirmation first obtains candidate Apple credentials in memory. A failed
   sign-in still leaves the current credentials/library intact. Once a valid
   different target is known, the coordinator advances the epoch, removes A's
   entire presentation and external surfaces, commits B's credentials, binds
   B's fresh store actors, stages B's scoped offline copy, and only then
   publishes B.

## Storage ownership and data lifecycle

Fresh actor instances are bound to immutable per-scope paths so an actor's
memory cache can never be reused across principals.

| Data | Owner and scoped location | Lifecycle |
|---|---|---|
| Credentials | Keychain `auth-credentials`; raw server ID only here | Legacy `user_id` is optional on decode; every new save requires it. Cleared only behind the privacy barrier. The legacy installation UUID remains device-local and is no longer transmitted because the server does not consume it. |
| Completed trips | `Application Support/Itinera/private/v1/<digest>/completed-trips-v1.json` | Protected, backup-excluded offline copy; replace/upsert only with a current lease. Clear Downloads removes the current scope's copy. |
| Trip progress | Same directory, `trip-progress-v1.json` | Device-local and scope-bound; never described as synced. Removed with current-scope downloaded data/deletion/logout. |
| Pending jobs | Same directory, `pending-jobs.json` | Loaded/reconciled only after Ready. Every mutation commit requires the initiating identity lease and its still-current server-readiness generation. |
| Pending submissions | Same directory, `pending-submissions.json` | Record and replay require the initiating identity lease and server-readiness generation. Recovery invalidates suspended commits before their final write; the captured scope/store is also checked before each POST and after each response. |
| Draft | `UserDefaults` key `itinera.private.v1.<digest>.tripDraft` | Restored only after Ready; removed for current-scope deletion/logout. Device preference defaults remain unscoped. |
| Locked stops | `itinera.private.v1.<digest>.lockedStops.<trip ID>` | Loaded after the editor enters the current private tree; never read in an initializer before identity. Removed for current-scope deletion/logout. |
| Widget snapshot | App Group v2 envelope plus active marker containing the opaque scope and presentation-session UUID | Load/save requires marker/envelope/lease match. Publication writes the scoped envelope first and the active marker last. Clearing removes the active marker first, then snapshot, then reloads timelines. These separate defaults writes are deliberately not described as atomic. |
| Live Activity | Activity attributes include the opaque scope and presentation-session UUID plus trip presentation | Start/update requires a current lease. Old and late activities are ended before target publication. Content is privacy-sensitive. |
| Local notifications | Identifier and `userInfo` include the opaque scope and presentation-session UUID | Adds and taps require the active session. Switch/logout/delete removes old pending and delivered requests. There is no APNs implementation in D2. |
| Deep links/navigation | Generic trip navigation includes only an opaque scope and presentation-session UUID; no trip/job payload | Missing, stale, wrong, or payload-bearing trip links are rejected. Invite mutation uses a separate explicit confirmation captured against the current session. Pending intents/errors are cleared on transition. |

Calendar events, exported PDFs, exported files or text, and prior shares
created by an explicit user action are external copies the app cannot revoke.
They remain after account/app-data deletion and must be removed separately.

All scoped files use atomic writes,
`completeUntilFirstUserAuthentication`, and backup exclusion. Settings such as
appearance, notification opt-in, and AI disclosure acceptance remain
device-wide because they do not contain a traveler's library content.

## Legacy migration and quarantine

No unscoped private value is ever assigned to the principal established during
upgrade. Earlier releases could silently change credentials while leaving the
global files behind, so even a current online `user_id` cannot prove ownership.

Before any private store read or submission replay, bootstrap idempotently
creates and verifies a protected retained copy of each known file, then removes
its replayable global source path, under the fixed inaccessible
`Application Support/Itinera/quarantine/unscoped-v1/` location:

- `completed-trips-v1.json`;
- `trip-progress-v1.json`;
- `pending-jobs.json`;
- `pending-submissions.json`.

Unscoped draft and locked-stop defaults are deleted, the v1 widget snapshot is
removed, unscoped Itinera notifications are removed, and unscoped Live
Activities are ended. A destination collision retains a protected uniquely
named copy so the replayable global path is always removed without overwriting
evidence. A protection or backup-exclusion failure leaves the global source in
place behind the privacy curtain for a deterministic retry. Quarantined
content is never
decoded, displayed, merged, or submitted; in particular, migration performs
zero network replay. Account deletion purges the quarantine. Rollback does not
make it safe to restore these values.

## Transition ordering and failure behavior

For a confirmed switch, logout, or replacement-session recovery:

1. Advance the coordinator epoch and mark the root Switching/Deleting.
2. Cancel API authentication and registered private work; destroy the private
   SwiftUI tree and synchronously clear published trip/job/cache/navigation
   state.
3. Set external active scope to none. Remove the Widget marker/snapshot and
   reload it, end Live Activities, remove pending/delivered local
   notifications, and clear deep-link/navigation intents. Teardown drains any
   notification add that began before invalidation, then independently
   verifies Widget, ActivityKit, and notification-center state before it can
   complete.
4. If any required external teardown cannot be confirmed, remain blocked with
   no private UI. Cleanup is idempotent and Retry repeats it.
5. Establish or commit target credentials only through the current epoch.
6. Create fresh target store actors and stage their cache/jobs without
   publishing.
7. Establish the target scope marker and coordinator lease, then atomically
   publish staged data and render a newly keyed private tree.
8. Remote library refresh and scoped pending replay may begin. Every result
   still checks the lease before persistence or publication.

Failures before step 5 retain the original credentials. Failures after the old
scope was unpublished never restore its UI under the target. If the target has
no scoped offline copy and the network refresh fails, the result is a truthful
empty/error state for the target—not a fallback to the previous library.

`Delete My Data` uses stricter durable ordering: write and verify an opaque
`serverDeletionPending` journal; publish Deleting and remove the private tree;
advance the identity barrier and invalidate auth; verify Widget, Activity, and
notification teardown; then send the transition-only DELETE with the retained
same-principal credential. A verified 204 advances the journal atomically to
`localCleanup` before any destructive local step. Every independent local
cleanup is attempted, and the journal is cleared only after all are verified.
No principal is bound or rendered during recovery. Once the server commits, a
Keychain error cannot skip local cleanup. A lost 204 remains safely journaled;
truthful convergence requires the integrated P2 retry-safe deletion contract
noted above. When a 401 requires same-principal refresh, a verified response
may supply the access token for that one DELETE retry even if Keychain cannot
persist the rotated credentials; cancellation and stale identity still fail
closed.
A local sign-out/new-session action sends no DELETE and never claims server
deletion.

## UI and accessibility contract

- Restoring, Switching, and Blocked are full-screen states with no private
  content behind them. Copy is literal: “Opening the private library saved on
  this iPhone,” “Switching private libraries. Nothing is being merged,” and
  “Itinera couldn't establish a private library.”
- Loading and errors use an icon or labeled progress indicator plus text;
  color or motion is never the only signal. The status is one ordered
  VoiceOver element and important changes are announced.
- Clear Downloads and replacement-guest creation are AppState-owned phases,
  so their literal copy survives destruction of the keyed Settings tree.
  Completion outcomes are operation-scoped: a new lifecycle operation clears
  stale result copy only after acquiring the transition gate, and the new
  outcome is announced after the replacement tree is established.
- Clear Downloads creates fresh same-principal store actors. If the initiating
  session is paused for server recovery—or a boundary pauses while clearing is
  in progress—the replacement lease remains paused and the UI returns to
  Recovery Required. Only a verified same-principal recovery may publish
  Ready again.
- Retry and confirmation controls retain at least 44 points (primary actions
  use 54). Layout scrolls at large Dynamic Type and 320-point compact widths.
- No behavior depends on animation, and existing press treatment continues to
  honor Reduce Motion.
- An online verified empty response may say the library is empty. Offline with
  no protected cache instead says that no trips are saved offline and a
  connection is needed to check the server; it never infers that the server
  library is empty.
- Previews cover Restoring, Switching, Clearing Downloads, replacement-guest
  creation, Blocked/Retry, established offline empty, Apple conflict copy, and
  compact accessibility text without touching live Keychain, network, stores,
  or standard defaults.

## Test plan

Focused deterministic tests must prove:

- legacy credential decoding, required new `user_id`, stable domain-separated
  digest vectors, and absence of raw IDs from every path/key/event;
- known-principal online and offline relaunch; legacy online upgrade; legacy
  offline fail-closed; missing-credential offline blocked;
- deterministic quarantine of every unscoped file/default/surface and zero
  requests from an unscoped pending submission;
- disjoint A/B completed trips, progress, jobs, submissions, drafts, and locks
  across relaunches and fresh actor instances;
- same-ID refresh, offline refresh failure, typed rejected-refresh recovery,
  different-ID rejection, no old-request retry with new credentials, and a
  delayed terminal R1 released after explicit recovery but before R2 that
  cannot relatch, save, retry, or pause a fresh R2 request;
- Apple same-library link, typed conflict, cancel, failed confirmation, and
  confirmed switch without a wrong-library frame;
- delayed A refresh/library/generation/mutation results and rapid A→B→A cannot
  save, publish, notify, or navigate after their epoch expires;
- Widget v1 rejection, v2 scope/marker matching, marker-first clear, stale save
  rejection; scoped Activity lifecycle; scoped notification add/remove/tap;
  and stale/missing private deep-link rejection;
- logout, Clear Downloads, trip deletion, and Delete My Data cleanup, including
  cleanup after server success plus Keychain failure;
- calm loading/error/empty copy, root tree reset, compact width, Dynamic Type,
  VoiceOver labels, 44-point controls, and Reduce Motion behavior.

Test doubles suspend individual storage, URL loading, notification, activity,
and surface-cleanup steps so ordering is asserted rather than inferred from
timing.

## Privacy impact, risks, rollback, and deletion

The new scope digest adds a pseudonymous local linkage label to protected app
and App Group storage. It prevents cross-principal lookup but is not encryption;
OS file protection and the Keychain remain required. Trip titles, stops, and
notification bodies are still visible on system surfaces according to the
traveler's iOS notification/Live Activity privacy settings, so Widget and
Activity content is marked privacy-sensitive where supported.

Known residual risks are intentionally bounded:

- This release has no cloud sync or cross-account merge. Progress and drafts
  from one scope never appear in another.
- Unscoped legacy progress/drafts may be irrecoverable because privacy takes
  precedence over guessing ownership.
- Calendar events, exported PDFs/files/text, and prior shares cannot be
  recalled by app deletion and must be removed separately.
- The full digest is a stable pseudonym. It must not be logged or shown even
  though it is not the raw server identifier.
- Local notifications only are supported; D2 does not claim APNs ownership or
  delivery behavior.
- A retained `serverDeletionPending` journal cannot converge when both access
  and refresh credentials are permanently rejected while the server subject
  still exists. The privacy curtain and journal remain in place; this release
  has no behind-curtain same-principal reauthentication or local-only
  abandonment action because either could falsely claim server deletion. A
  support/re-verification flow is required before beta. Network failures may
  use Resume Deletion, but credential rejection must be described as needing
  account re-verification rather than as a generic connectivity retry.
- Operations must keep deletion-token verification keys and issuer/audience
  configuration valid for at least the maximum supported retained-journal
  lifetime. Rotating those keys sooner strands a legitimate pending deletion
  behind the privacy curtain until the same-principal re-verification flow is
  available.
- A lost successful refresh response can still strand deletion after the
  backend refresh-family rotation grace expires (currently an integration
  assumption of approximately 30 seconds). D2 deliberately does not replay a
  refresh automatically because it cannot prove whether rotation committed.
  P2 makes a lost DELETE response retry-safe; it does not make a lost refresh
  response retry-safe. Same-principal re-verification remains the recovery path
  after that grace window.
- The cleanup journal is app-container data and cannot survive uninstall,
  while Keychain credentials may survive. Backend P2 operations therefore need
  an explicit retention/orphan-cleanup policy for accounts whose client-side
  deletion journal disappears before convergence.

Rollback to the baseline can recreate unsafe global files and cannot safely
read or merge scoped directories. Before rollback, disable account switching,
submission replay, and private offline rendering in the old client release or
ship a forward fix. Preserve scoped directories; never flatten them. The D2
reader ignores global legacy paths permanently. Removing D2 code is therefore
not a data migration strategy.

After confirmed server deletion, Delete My Data removes the established current
scope, credentials, App Group snapshot, Live Activities, local notifications,
pending navigation, and the unscoped quarantine. Calendar events, exported
PDFs/files/text, and prior shares remain. Switching retains the old scoped
directory but makes it inaccessible until that same server principal is
established again. Clear Downloads removes current completed trips and progress
and immediately unpublishes any Widget/Activity that depends on them; server
copies remain. A local sign-out removes current device-private data and
credentials but does not claim to delete server data or external artifacts.

## Acceptance and validation gates

- [x] Private UI and local replay cannot begin before a server-established or
  previously persisted principal lease exists.
- [x] Every private store and external event is scoped by the opaque digest;
  raw principal IDs appear only in the credential/session boundary.
- [x] Legacy private state is quarantined/deleted and never auto-claimed or
  submitted.
- [x] Refresh rejection and Apple conflict are typed identity outcomes; neither
  silently replaces credentials or crosses principals.
- [ ] Sprint P2 is deployed before D2, including signed absent-subject `204`,
  existing-subject `401`, strict claim validation, and an operational
  deletion-key retention window.
- [x] Confirmed switch/logout/delete teardown completes before target render;
  stale async work and A→B→A are rejected by epoch.
- [x] Previously established principal opens its scoped library offline.
- [x] Accessible loading, error, conflict, offline-empty, and new-empty states
  are implemented and previewed.
- [x] Focused identity/storage/surface/race tests and the full iOS suite pass.
- [x] XcodeGen 2.45.4 run twice produces byte-identical output.
- [x] Debug test build, full Debug tests, and Release simulator build with an
  injected HTTPS production URL succeed without warnings.
- [x] Built Info.plist endpoint, ATS policy, source plists, existing OpenAPI
  contract, transport checks, and `git diff --check` pass.
- [x] Independent read-only senior design/privacy review has no unresolved
  material finding; affected gates are rerun after fixes.

## Validation evidence

- XcodeGen 2.45.4 was run twice from `ios/`; all three generated project files
  were byte-identical. The `project.pbxproj` SHA-256 remained
  `35f2a83ec6eb9a8c97acfd738e9f5d4ac811736f87a5ff53a12b8d68a2862541`
  after both runs.
- A clean Debug `build-for-testing` succeeded against the iPhone 17 Pro
  simulator. `test-without-building` then executed 209 tests with zero
  failures. A separate generic-simulator Debug app build also succeeded.
- A clean Release simulator build succeeded with
  `ITINERA_PRODUCTION_API_BASE_URL=https://api.example.invalid` and signing
  disabled. Debug test-build, full-test, Debug app, and Release logs contain
  zero compiler `warning:` and zero `error:` diagnostics.
- Source and built plists lint successfully. The built Release app contains
  `ItineraAPIBaseURL=https://api.example.invalid`; no ATS exception dictionary
  is present, so platform HTTPS defaults apply. The embedded privacy manifest
  lints and declares linked, non-tracking user ID and email collection in
  addition to the existing location/user-content disclosures.
- Backend Ruff and the committed OpenAPI contract check pass. The complete
  backend suite executes 142 tests with zero failures.
- Production scans find no `X-Installation-Id` transmission, identity logging,
  raw principal outside the credential/session boundary, arbitrary-load ATS
  exception, build product, DerivedData, `xcuserdata`, or immutable source
  flag. `git diff --check` passes.
- The frozen iOS source/configuration manifest SHA-256 is
  `546a7cde53614d44f7fa8bd5c53fb638344109cbaf1791547557ae5fe9615f85`.
- Sprint P2 deployment remains an intentionally open release gate. D2 must not
  ship until the retry-safe signed-subject deletion contract and operational
  key-retention window described above are deployed and verified.
- Independent read-only product/design and privacy reviews found no unresolved
  P0/P1 after remediation. Their findings drove a single announced recovery
  status, an adaptive accessibility-size outcome banner, atomic recovery pause
  before API errors, Recovery Required preservation across Clear Downloads,
  payload-free generic trip URLs, verified Widget/Activity/notification
  teardown, and draining of pre-invalidation notification adds. The affected
  focused suites and every full gate above were rerun afterward.
- The smallest follow-up sprint is private same-principal re-verification plus
  a non-public support channel and published privacy policy, followed by an
  XCUITest smoke suite. P2 backend work should also document deletion-journal
  retention/orphan cleanup before external beta.
