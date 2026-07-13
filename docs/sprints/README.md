# Itinera delivery program

**Program started:** July 13, 2026
**Mainline baseline:** `ed130e8`
**Product direction:** an adaptive, offline-first pocket field guide

This directory is the durable sprint ledger for coordinated engineering and
design work. Each sprint owns a small vertical outcome, records its acceptance
criteria before implementation, and ends with tests, a commit, a pushed branch,
and a handoff suitable for review or integration.

## Active ownership

| Track | Owner task | Sprint | Scope boundary |
|---|---|---|---|
| Platform | Itinera Senior SWE — Correct Trip State | Sprint P1 | Backend correctness, contracts, tests, operational safety; no campaign-site changes |
| Product design | Itinera Design Pro — Adaptive Today | Sprint D1 | SwiftUI Today experience, truthful route timing, accessibility, previews/tests; no backend schema or campaign-site changes |
| Integration | Program lead | Integration I1 | Review handoffs, order integration, rerun the complete matrix, update this ledger, and start the next bounded sprints |

The implementation tasks run in isolated Codex worktrees created from the same
clean `main` revision. This prevents the shared-checkout branch switching and
cross-session file collisions that occurred during earlier parallel work.

## Sprint P1 — Correct Trip State

### Outcome

A server-accepted itinerary revision can never be hidden by a stale Redis
terminal result.

### Committed scope

- make terminal-result caching version-aware or invalidate/update it at every
  relevant mutation boundary;
- preserve PostgreSQL as the authorization and source-of-truth boundary;
- add regressions for revision followed by status fetch, Redis failure, and
  ordinary generation completion;
- document the cache contract and validation evidence;
- take at most one adjacent foundation improvement if the core work is fully
  verified and remains coherent.

### Acceptance criteria

- a status fetch after revision returns the active PostgreSQL version/result;
- stale or malformed cached data cannot supersede newer durable state;
- Redis unavailability preserves correct API behavior;
- Ruff, backend tests, OpenAPI drift, Alembic static upgrade, Compose
  validation, and `git diff --check` pass;
- the owner pushes one reviewable branch and reports its commit and risks.

## Sprint D1 — Adaptive Today

### Outcome

Today mode communicates route timing truthfully and provides a calm entry point
for adjusting a day when travel no longer matches the plan.

### Committed scope

- use existing route data for ETA/leave-by presentation where it is genuinely
  available;
- retain an explicit planned-time fallback when live timing is unavailable;
- add one polished running-late/adjustment entry point without auto-applying or
  inventing itinerary changes;
- define loading, offline, error, stale, small-screen, Dynamic Type, VoiceOver,
  and reduced-motion behavior;
- add deterministic tests and previews around the new state model.

### Acceptance criteria

- the UI never labels a planned start time as a live leave-by time;
- route-derived timing exposes its mode/freshness or degrades to planned time;
- locked/completed stops are not silently changed;
- XcodeGen is deterministic, iOS tests pass, and Debug and Release simulator
  builds succeed;
- the owner pushes one reviewable branch with a design and implementation
  handoff.

## Integration order

1. Review the platform branch for cache/source-of-truth correctness and merge
   or request corrections.
2. Rebase the design branch on the accepted platform state only if it requires
   overlapping contracts; otherwise keep the changes independently reviewable.
3. Run the full backend, iOS, web, OpenAPI, migration, Compose, and release
   matrix on the combined candidate.
4. Update the roadmap's implemented evidence and this ledger with actual test
   counts, branches, commits, known risks, and rollback notes.
5. Push the integration branch and start the next sprints from the new accepted
   mainline.

## Next sprint queue

The queue is ordered by dependency, not novelty:

1. principal-scoped offline storage and identity-safe device switching;
2. stable stop-ID mutation targets, client mutation IDs, and conflict UX;
3. targeted APNs generation completion with direct trip deep links;
4. route-aware running-late refinement proposals with preview/approve/undo;
5. cursor-paginated trip summaries and lazy detail loading;
6. real reservation/document extraction with review and duplicate detection;
7. real-infrastructure CI, readiness probes, bounded job retries, and spend
   ceilings;
8. optional on-device Foundation Models assistance on supported Apple devices.

## Definition of done for every sprint

- scope, dependencies, data flow, failure states, privacy impact, and rollback
  are written before broad implementation;
- server mutations are authorized, concurrency-safe, and idempotent;
- user-facing changes include accessibility, offline, loading, empty, and error
  states;
- OpenAPI and Swift contracts remain compatible;
- focused tests plus the relevant full suites pass;
- documentation reflects what was actually implemented rather than intent;
- changes are committed intentionally and pushed on a scoped branch;
- the handoff names remaining risks and proposes the next smallest sprint.

## Program log

### July 13, 2026

- created isolated Senior SWE and Design Pro tasks from `ed130e8`;
- started Sprint P1 and Sprint D1 in parallel;
- established `codex/sprint-program` as the coordination/documentation branch.
