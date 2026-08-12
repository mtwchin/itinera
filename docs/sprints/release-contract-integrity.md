# Sprint P41 — Release contract integrity

**Started:** August 1, 2026  
**Branch:** `codex/release-contract-integrity`  
**Baseline:** `a5a5dd2`; concurrent integration tip `25f99cb`  
**Status:** In progress; first regression-repair tranche is locally validated.

## Outcome

Produce one self-contained revision that a clean checkout can migrate, generate,
build, test, and explain. New product work remains behind this gate because the
current branch is green only when untracked local files are present.

## Audit decision

The repository-wide audit found that release integrity, rather than another
feature, is the highest-priority sprint:

- the tracked `a3e7c1f9b204` migration declares untracked revision
  `8b7c90509f1d` as its parent, and that revision depends on two more untracked
  migrations;
- the generated Xcode project and `project.yml` require untracked
  `LocalPrincipalScope.swift` and `ItineraUITests.swift` sources;
- tracked planning documents link to 37 sprint records that exist only as
  untracked files;
- the committed OpenAPI artifact omitted the new `Activity.source_platforms`
  field;
- the full local iOS run initially failed 13 unit assertions and one UI test,
  exposing broken session decoding, terminal SSE handling, scoped widget
  selection, and explicit invite-decline presentation.
- the APNs migration added concurrently at `25f99cb` emitted the same index
  creation twice, and its registration endpoint advertised a JSON `200` while
  the operation is a no-content upsert.

The existing untracked files predate this sprint and remain user-owned. They
must be intentionally reviewed and included or their committed references must
be removed; this sprint does not silently discard or claim them.

## Sprint scope

1. Restore API-contract generation and verify the social-source field is in the
   checked-in schema.
2. Repair the iOS regressions found by the full simulator run:
   - decode required `user_id` session identity under the configured JSON key
     strategy;
   - flush a complete terminal SSE frame when the connection closes at EOF;
   - use one validated opaque widget-snapshot key contract in app and widget;
   - present invite acceptance with an explicit, automatable decline action.
3. Add regression coverage for EOF stream delivery and principal-scoped widget
   keys.
4. Add a CI documentation-integrity gate that rejects missing and locally
   untracked Markdown targets.
5. Reconcile the privacy manifest with the email requested and persisted for
   Sign in with Apple account recovery.
6. Review the missing migrations, Swift sources, UI tests, and sprint records,
   then make the intended revision self-contained.
7. Prove the result from a clean source archive, not only the dirty working
   tree.
8. Keep the concurrently added APNs contract deployable: generate each index
   once, advertise an explicit `204` registration response, and cover both
   contracts with regression tests.

## Acceptance criteria

- [x] A focused `codex/` sprint branch exists without rewriting concurrent user
  work.
- [x] `api/openapi.json` includes `Activity.source_platforms` and the OpenAPI
  drift check passes.
- [x] Focused authentication, streaming, trip-mutation, and invite-consent tests
  pass after the first repair tranche.
- [x] CI has a deterministic local-link/tracked-target documentation check with
  unit coverage.
- [x] The privacy manifest declares the linked, non-tracking email address used
  for Apple account recovery.
- [x] Offline migration SQL has no duplicate index names and is covered by a
  regression test.
- [x] The device-token endpoint and generated OpenAPI agree on a no-content
  `204` response.
- [ ] Every required Alembic revision is reviewed and tracked; there is one
  resolvable committed head and an online PostgreSQL upgrade passes.
- [ ] Every source referenced by XcodeGen is reviewed and tracked; two
  consecutive generations are byte-identical.
- [ ] Every linked sprint record is reviewed and either tracked with truthful
  status or removed from current documentation.
- [ ] The documentation-integrity check passes.
- [ ] All backend unit and real-infrastructure tests pass.
- [ ] The full iOS scheme, including UI tests, passes from a clean archive.
- [x] Debug and Release simulator builds pass in the working tree with the
  production URL/ATS assertions.
- [x] Website lint, production build, and rendered-HTML tests pass.
- [ ] The final diff contains no secrets, build products, simulator state, or
  unrelated refactors.

## Verification

```bash
./venv/bin/ruff check backend tests scripts
./venv/bin/python -m pytest tests -q
./venv/bin/python scripts/check_docs.py
./venv/bin/python scripts/export_openapi.py --check
./venv/bin/alembic heads
./venv/bin/alembic upgrade head --sql > /dev/null
docker compose config --quiet

RUN_REAL_INFRA_TESTS=1 \
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
REDIS_URL=redis://localhost:6379/0 \
./venv/bin/python -m pytest -m integration -q

cd website
npm run lint
npm test

cd ../ios
xcodegen generate
xcodebuild -project Itinera.xcodeproj -scheme Itinera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The final reproducibility check must create an archive from the intended Git
tree in a temporary directory and rerun migration resolution, documentation
integrity, XcodeGen drift, backend tests, and iOS tests there.

Current working-tree evidence on August 1, 2026:

- Ruff passed; backend tests: 295 passed, 20 real-infrastructure tests skipped.
- OpenAPI drift, privacy-manifest syntax, offline Alembic SQL, Alembic head, and
  Docker Compose configuration checks passed.
- XcodeGen completed without changing the committed project; the full iOS
  scheme (unit plus UI tests) passed and the Release simulator build passed.
- Website lint, production build, and two rendered-HTML tests passed.
- Documentation integrity intentionally remains red: 70 link occurrences point
  at 37 untracked sprint files.
- A clean-tree migration/UI proof remains impossible until the three untracked
  migration ancestors, `LocalPrincipalScope.swift`, and `ItineraUITests.swift`
  are intentionally integrated or their tracked references are removed.

## Following sprint queue

1. **Consent-at-provider boundary:** recheck a persisted consent grant
   immediately before hosted generation transmission and define withdrawal for
   queued work.
2. **Refresh and paid-work concurrency:** make refresh recovery deterministic
   and single-use; add bounded, idempotent admission for AI edits after
   product/finance approves the spend contract.
3. **Trust surface and internal beta:** reconcile email collection with the
   privacy manifest/App Store disclosure, publish approved privacy/support
   destinations, prove staging, and produce a signed TestFlight artifact.
4. **Job-system fault qualification:** run real dispatcher/worker/broker-loss
   and worker-kill tests, then approve a measurable duplicate-cost SLO.
5. **Production operability:** private metrics/traces, worker correlation,
   alerts, retention jobs, restore rehearsal, and a support runbook.
6. **Scale after evidence:** cursor-based trip summaries, bounded parallel
   geocoding with cache/freshness controls, and measured capacity tests.
7. **APNs production readiness:** provision and validate deployment settings,
   retry registration on later launches, invalidate rejected tokens, bound
   dispatch latency outside the generation worker, reuse provider JWTs, and add
   provider-response/lifecycle tests without logging token material.
