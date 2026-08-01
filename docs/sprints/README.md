# Itinera delivery program

**Program started:** July 13, 2026

**Mainline baseline:** `ed130e8`

**Current integration branch:** `codex/sprint-1-integration`

**Product direction:** an adaptive, private, offline-first pocket field guide

This directory is the durable sprint ledger for coordinated engineering and
design work. Each sprint owns a bounded outcome, records acceptance criteria
before implementation, and ends with independent review, test evidence, an
intentional commit, a pushed branch, and an integration handoff.

## Program status

| Track | Owner task | Sprint | Status and boundary |
|---|---|---|---|
| Platform | Itinera Senior SWE — Correct Trip State | P1 | Complete and review-clear; backend state correctness, SSE lifecycle, deletion/privacy transition |
| Product design | Itinera Design Pro — Adaptive Today | D1 | Complete and review-clear; SwiftUI Today timing, accessibility, previews, and deterministic tests |
| Integration | Program lead | I1 | Complete; combined gate green and accepted for downstream sprints |
| Next platform | Fresh Senior SWE task from accepted I1 | P2 | Atomic admission, stream caps, and honest API readiness; backend only |
| Next product | Fresh Design Pro/iOS privacy task from accepted I1 | D2 | Principal-scoped offline identity and safe account switching; iOS only |
| Failure contract | Program lead | P3 | Locally validated; public-safe terminal generation codes, legacy-error purge, and iOS-compatible API contract; awaiting intentional review/integration |
| Beta cost boundary | Program lead | P4 | Locally validated; seven-night cap for new requests plus versioned queued-job compatibility; awaiting intentional review/integration |
| CI tool integrity | Program lead | P5 | Locally validated; XcodeGen archive checksum is verified before CI extraction/execution; awaiting intentional review/integration |
| CI action pinning | Program lead | P6 | Locally validated; every CI action resolves to an immutable commit ID; awaiting intentional review/integration |
| Composer attempt ledger | Program lead | P7 | Real-infrastructure validated locally; terminal writes persist privacy-safe provider/model/prompt/latency records for every composer attempt; awaiting intentional review/integration |
| Provider usage ledger | Program lead | P8 | Real-infrastructure validated locally; provider-reported input/output token counts are recorded when available, with unknown usage explicit; awaiting intentional review/integration |
| Server-authoritative AI consent | Program lead | P9 | Real-infrastructure validated locally; versioned grant/withdrawal audit and fail-closed generation/refinement gate; awaiting intentional review/integration |
| Bounded job recovery | Program lead | P10 | Real-PostgreSQL dispatch rule validated; bounded worker deadlines and lease-aware outbox recovery avoid timer-driven queued-job redelivery; worker-kill/broker fault validation remains |
| Worker provider preflight | Program lead | P11 | Locally validated; the generation worker rejects missing provider SDK/configuration before consuming broker work; awaiting intentional review/integration |
| Explicit AI-edit provider and budget | Program lead | P12 | Locally validated; edits use only the consented selected provider with bounded output, disabled SDK retries, and safe provider-failure handling; awaiting intentional review/integration |
| AI-edit attempt ledger | Program lead | P13 | Real-PostgreSQL validated; every post-call edit outcome records privacy-safe provider/usage/latency metadata; awaiting intentional review/integration |
| Apple recovery local-data isolation | Program lead | P30 | Locally validated; explicit existing-library recovery purges prior account local state before library refresh; awaiting intentional review/integration |
| Recoverable iOS API configuration | Program lead | P31 | Locally validated; malformed deployment configuration presents an accessible launch failure rather than terminating the app; awaiting intentional review/integration |
| Explicit invite deep-link consent | Program lead | P32 | Locally validated; collaboration invite links require traveler confirmation before any membership write; awaiting intentional review/integration |
| Account-transition presentation cleanup | Program lead | P33 | Locally validated; deletion and recovery clear prior-principal widget and Live Activity surfaces; awaiting intentional review/integration |
| Serialized account refresh | Program lead | P34 | Locally validated; deletion shares one rotating refresh with concurrent authenticated requests; awaiting intentional review/integration |
| Persisted principal identity | Program lead | P35 | Locally validated; credentials retain server-issued principal identity with legacy decoding and refresh consistency checks; awaiting intentional review/integration |
| Required session principal | Program lead | P36 | Locally validated; missing session `user_id` fails closed before credentials or private state can be created; awaiting intentional review/integration |
| Principal-scoped store primitives | Program lead | P37 | Locally validated; opaque scoped constructors isolate core file-backed private stores; integrated by P38 |
| Principal-scoped core state bootstrap | Program lead | P38 | Locally validated; authenticated startup namespaces core private stores and purges unproven legacy core data; P39 scopes drafts and locks |
| Principal-scoped drafts and locked stops | Program lead | P39 | Locally validated; drafts and locks activate the authenticated namespace before reading or writing; P40 closes cold-start presentation leakage |
| Principal-scoped presentation state | Program lead | P40 | Locally validated; widget snapshots use an opaque active-principal selection and cold activation clears Live Activities and Itinera notifications |
| Stable stop-ID mutation targets, client mutation IDs, conflict UX | Program lead | P41 | Locally validated; remove/reorder/replace accept stable `activity_id`; client-generated `mutation_id` deduplicates retries; 409 conflict sheet with reload/discard; see [stable-stop-mutations.md](stable-stop-mutations.md) |
| APNs generation completion with direct trip deep links | Program lead | P42 | Locally validated; device-token registration endpoint, `device_tokens` table, httpx/h2 APNs client, ES256 JWT signing, post-generation dispatch, iOS entitlement + delegate wiring; see [apns-generation-completion.md](apns-generation-completion.md) |
| Privacy release artifacts | Program lead | Audit | Privacy manifest validates and is bundled; public policy/support/legal artifacts await approved destinations; see [privacy-release-artifacts.md](privacy-release-artifacts.md) |

The implementation tasks run in isolated Codex worktrees created from the same
accepted revision. Platform and iOS sprints are file-disjoint where practical;
the integration branch is the only place their complete validation matrix is
accepted.

## Sprint P1 — Correct Trip State

### Accepted outcome

PostgreSQL is now the sole authority for itinerary state, content,
authorization, and versioning. Redis carries only ephemeral progress hints;
the terminal itinerary cache and Celery result retention path are removed.

Delivered on `codex/correct-trip-state`:

- `ae83186` — `fix: keep trip revisions cache-coherent`
- `787a120` — `fix: make itinerary state database-authoritative`

The second commit deliberately simplifies the first design rather than adding
another coherence protocol:

- status reads return the already-authorized PostgreSQL row;
- SSE subscribes before a fresh authoritative reconciliation, polls with a
  new short-lived session, bounds every Redis operation, preserves healthy
  idle subscriptions, and closes after a configurable five-minute reconnect
  boundary;
- workers commit before optional publish, return only compact metadata, use
  `ignore_result=True`, and never write itinerary documents to Redis;
- account deletion prelocks the two audited child-first writer families in a
  deterministic order without enumerating cache keys;
- the rollout runbook inventories real endpoint/database targets, derives its
  wait from observed TTL/PTTL values, gates Delete My Data through the legacy
  retention window, and prohibits an unsafe legacy-writer rollback.

Independent review found no remaining P1/P2 blocker. The distributed
per-principal concurrent-stream cap is explicitly assigned to P2.

## Sprint D1 — Adaptive Today

### Accepted outcome

Today now gives the traveler an honest route-aware answer without claiming to
know their location or silently changing their itinerary.

Delivered on `codex/adaptive-today`:

- `0f1d489` — `feat(ios): add route-aware adaptive Today`

The vertical slice includes:

- traveler-first hierarchy: current stop and one-tap directions before timing;
- named planned-leg timing with walking, driving, and transit selection;
- current-route ETA semantics for walking/driving and past transit;
- scheduled arrive-by semantics for future transit, including an explicit
  recheck state when the calculated departure has passed;
- fail-closed planned-time fallback for missing/invalid destination time zones,
  malformed times, skipped origins, cancellation, offline/provider failure,
  and invalid route data;
- stale-request and initial-progress race protection;
- a non-mutating Running Late entry into the existing editor with precise
  quick-refinement lock copy;
- Dynamic Type fallbacks, ordered VoiceOver summaries, Reduce Motion support,
  44-point controls, and a real compact-width preview.

Independent design review found no remaining correctness, UX-truthfulness,
accessibility, privacy, project-inclusion, preview, test, or documentation
blocker. Route estimates remain intentionally transient and are not published
to Widget or Live Activity surfaces until those contracts carry time-zone and
route-basis provenance.

## Integration I1 evidence

Accepted commits on `codex/sprint-1-integration`:

- `0c35722` — integrated D1
- `df4e89b` and `7cb9603` — integrated P1

Complete combined validation on July 13, 2026:

- Ruff passed across `backend`, `tests`, and `scripts`.
- All **142 backend tests** passed, 11 above the 131-test baseline.
- The committed OpenAPI contract is current.
- Alembic reports one head (`f61d2a8b9c43`) and emitted the complete static
  PostgreSQL upgrade.
- Docker Compose validation passed.
- Campaign-site ESLint, production build, and **2/2 rendered HTML tests**
  passed.
- Two consecutive XcodeGen runs were byte-identical; project SHA-256 is
  `efff34c98be10f86530d9c95cd4ea2f85c1b958e94af11dc61ef00fd12d4f903`.
- All **87 iOS tests** passed, including 19 focused Today tests.
- Debug test and Release simulator builds succeeded without warnings.
- The Release artifact contains `https://api.example.test` and no arbitrary
  transport-security load override.
- `git diff --check` passed and the integration worktree was clean before this
  ledger update.

## Next sprint contracts

### P2 — Atomic Admission and Honest API Readiness

**Owner:** fresh Senior SWE / Platform Lead task

**Suggested branch:** `codex/p2-atomic-admission-readiness`

Outcome: the API admits expensive work atomically and reports readiness only
for dependencies the API role can actually prove.

Committed scope:

- replace split Redis `INCR`/`EXPIRE` admission with one atomic, versioned
  per-principal plus global decision and deterministic `Retry-After`;
- bound Redis connect/read operations, fail closed with a typed 503, and add an
  operational generation kill switch;
- add a distributed per-principal concurrent-SSE lease/cap compatible with the
  P1 reconnect boundary, including stale-lease recovery;
- keep `/healthz` as process liveness and make `/readyz` verify PostgreSQL,
  current migration head, Redis/admission, and API-role production config;
- make Compose/Render health checks use readiness where traffic routing needs
  it;
- add real PostgreSQL/Redis CI coverage for concurrent admission and readiness;
- version keys and document safe rollback.

Out of scope: provider/worker-health claims, spend ledgers, App Attest, and job
retry semantics.

### D2 — Private Offline Identity

**Owner:** fresh Design Pro / Senior iOS Privacy Lead task

**Suggested branch:** `codex/d2-private-offline-identity`

Outcome: no traveler can see, publish, submit, or mutate another principal's
offline state when identity is restored, linked, or switched.

Committed scope:

- persist the server-issued user ID with credentials while retaining safe
  legacy decoding;
- complete identity bootstrap before loading or publishing private trip state;
- namespace completed trips, progress, pending jobs/submissions, drafts, and
  locked-stop state by an opaque principal digest;
- scope the App Group widget snapshot and remove old-principal Widget, Live
  Activity, and notification state before publishing the new principal;
- handle Apple-link/account-switch outcomes explicitly without briefly showing
  the wrong library;
- quarantine or fail closed on unscoped legacy data; never submit an unscoped
  pending request;
- preserve offline use for a previously established principal;
- add deterministic migration, relaunch, offline, and rapid-switch tests plus
  accessible loading/error/empty states.

Out of scope: backend API changes, cross-account library merging, and cloud
sync.

## Following queue

After P2/D2, re-rank from evidence rather than novelty:

1. stable stop-ID mutation targets, client mutation IDs, and conflict UX;
2. targeted APNs generation completion with direct trip deep links;
3. route-aware running-late refinement proposals with preview/approve/undo;
4. cursor-paginated trip summaries and lazy detail loading;
5. reservation/document extraction with review and duplicate detection;
6. bounded job retries, retention jobs, and spend ceilings; public terminal
   failure codes are implemented locally in [P3](safe-generation-failures.md);
7. deterministic schedule feasibility and a model-quality evaluation ledger;
8. optional on-device Foundation Models assistance on supported Apple devices.

## Definition of done for every sprint

- scope, dependencies, data flow, failure states, privacy impact, and rollback
  are written before broad implementation;
- server mutations are authorized, concurrency-safe, and idempotent;
- user-facing changes include accessibility, offline, loading, empty, and error
  states;
- OpenAPI and Swift contracts remain compatible or migrate explicitly;
- focused tests plus the relevant full suites pass;
- at least one independent read-only review clears the final diff;
- documentation reflects what was implemented rather than intent;
- changes are committed intentionally and pushed on a scoped branch;
- the handoff names remaining risks and proposes the next smallest sprint.

## Program log

### July 16, 2026

- started P3 to remove raw worker/provider exception text from the public
  generation-job contract;
- added stable public error codes, a legacy-row sanitization migration, and
  backward-compatible iOS decoding; detailed context and remaining risks are
  in [safe-generation-failures.md](safe-generation-failures.md);
- recorded an unrelated active social-source pipeline test regression rather
  than changing another in-progress feature.
- started P4 to enforce the approved seven-night beta generation boundary;
  [beta-trip-cap.md](beta-trip-cap.md) records new/queued/legacy-draft behavior
  and the migration rollback boundary.
- started P5 to verify the pinned XcodeGen release archive before CI extraction;
  [ci-tool-integrity.md](ci-tool-integrity.md) records the digest and remaining
  supply-chain scope.
- started P6 to pin all executed GitHub Actions to immutable commits; see
  [ci-action-pinning.md](ci-action-pinning.md).
- started P7 to persist privacy-safe composer-attempt records for cost and
  reliability accounting; see [composer-attempt-ledger.md](composer-attempt-ledger.md).
- started P8 to normalize provider-reported token usage into those attempt
  records without estimating unavailable usage; see
  [provider-usage-ledger.md](provider-usage-ledger.md).
- started P9 to move AI consent from a device-local acknowledgement to a
  server-authoritative, revocable audit gate; see
  [server-authoritative-ai-consent.md](server-authoritative-ai-consent.md).
- audited privacy release artifacts: the manifest is valid and bundled, but
  public policy/support/legal destinations are not yet approved or configured;
  see [privacy-release-artifacts.md](privacy-release-artifacts.md).
- started P10 to bound worker execution and recover only expired execution
  leases rather than repeatedly republishing broker-backlogged jobs; see
  [bounded-job-recovery.md](bounded-job-recovery.md).
- started P11 to validate the selected composer and production discovery/maps
  contract before a worker can consume queued generation work; see
  [worker-provider-preflight.md](worker-provider-preflight.md).
- started P12 to make AI edits use the explicitly selected provider with a
  bounded output budget and safe provider failures; see
  [explicit-ai-edit-provider.md](explicit-ai-edit-provider.md).
- started P13 to persist privacy-safe AI-edit provider attempts, including
  rejected and failed edits; see [ai-edit-attempt-ledger.md](ai-edit-attempt-ledger.md).
- started P15 to exact-pin the direct hosted-provider SDKs so routine builds
  cannot silently resolve a newer provider client; see
  [provider-sdk-pinning.md](provider-sdk-pinning.md).
- started P16 to block CI on dependency, secret, and runtime-container scans;
  see [supply-chain-scanning.md](supply-chain-scanning.md).
- started P17 to provide privacy-safe API support correlation without trusting
  caller-supplied identifiers; see [request-correlation.md](request-correlation.md).
- started P18 to bound HTTP request allocation before route parsing; see
  [request-body-limit.md](request-body-limit.md).
- documented the required product/finance inputs for the pending P21 atomic
  spend-admission work; see
  [spend-admission-decision-record.md](spend-admission-decision-record.md).
- started P22 to disable unauthenticated production metrics until an internal
  scrape path is approved; see [metrics-exposure.md](metrics-exposure.md).
- started P23 to apply no-store and browser security headers to API responses;
  see [api-security-headers.md](api-security-headers.md).
- started P24 to add a deterministic, network-independent XCUITest launch
  gate; see [deterministic-ui-test.md](deterministic-ui-test.md).
- started P26 to prefer the authenticated owner-scoped itinerary stream with
  bounded reconnects and status-poll fallback; see
  [authenticated-sse-client.md](authenticated-sse-client.md).
- started P27 to prevent rejected refresh tokens from silently replacing an
  existing trip library with a new guest identity; see
  [refresh-identity-preservation.md](refresh-identity-preservation.md).
- started P28 to make generation progress and identity-recovery errors usable
  with VoiceOver and non-futile actions; see
  [generation-accessibility-recovery.md](generation-accessibility-recovery.md).
- started P29 to prevent invalid AI-edit output from appearing in client error
  messages; see [safe-ai-edit-validation-errors.md](safe-ai-edit-validation-errors.md).
- started P30 to purge the prior account's local trip state before an explicit
  Apple existing-library recovery refreshes the device; see
  [apple-recovery-local-data-isolation.md](apple-recovery-local-data-isolation.md).
- started P31 to turn missing or invalid compiled API configuration into an
  accessible launch failure instead of a crash; see
  [recoverable-ios-api-configuration.md](recoverable-ios-api-configuration.md).
- started P32 to require explicit traveler consent before a collaboration
  invite deep link can accept membership; see
  [explicit-invite-deep-link-consent.md](explicit-invite-deep-link-consent.md).
- started P33 to remove prior-principal widget and Live Activity state during
  deletion or existing-library recovery; see
  [account-transition-presentation-cleanup.md](account-transition-presentation-cleanup.md).
- started P34 to serialize deletion retries with ordinary rotating session
  refreshes; see [serialized-account-refresh.md](serialized-account-refresh.md).
- started P35 to persist the server-issued principal UUID with credentials as
  the D2 cache-namespacing foundation; see
  [persisted-principal-identity.md](persisted-principal-identity.md).
- started P36 to require the server principal identifier in every new or
  refreshed client session; see
  [required-session-principal.md](required-session-principal.md).
- started P37 to provide opaque, versioned per-principal constructors for core
  offline stores; see
  [principal-scoped-store-primitives.md](principal-scoped-store-primitives.md).
- started P38 to bootstrap the authenticated principal before AppState reads or
  writes core offline stores; see
  [principal-scoped-core-state.md](principal-scoped-core-state.md).
- started P39 to scope trip-form drafts and locked-stop preferences through
  AppState; see
  [principal-scoped-drafts-and-locks.md](principal-scoped-drafts-and-locks.md).
- started P40 to prevent the widget and Lock Screen from selecting an
  unscoped prior-principal presentation; see
  [principal-scoped-presentation-state.md](principal-scoped-presentation-state.md).
- added regression proof that downloaded-data and server-confirmed account
  deletion purge the completed itinerary cache, local stop progress, and
  draft/locked-stop preferences, queued trip records, credentials, and the
  device-scoped installation identifier; the replay path never creates a guest
  account while local cleanup is incomplete; see
  [offline-cache-deletion-proof.md](offline-cache-deletion-proof.md).
- restored the full iOS simulator build after a SwiftUI type-check timeout in
  the trip-library closure; see [ios-library-build-unblock.md](ios-library-build-unblock.md).

### July 13, 2026

- created and pinned isolated Senior SWE and Design Pro tasks from `ed130e8`;
- established `codex/sprint-program` with the coordinated delivery contract;
- corrected P1 from version-aware caching to a simpler PostgreSQL-authoritative
  model after race, privacy, lifecycle, and rollout review;
- corrected D1 through independent hierarchy, transit-basis, time-zone,
  cancellation, parsing, accessibility, and copy review;
- accepted and integrated P1/D1 after independent review and complete gates;
- prepared the mutually file-disjoint P2/D2 contracts for fresh task chats
  starting from the pushed I1 revision.
