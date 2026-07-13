# Sprint P1: Correct Trip State

- **Started:** July 13, 2026
- **Baseline:** `ed130e8` (`origin/main`)
- **Branch:** `codex/correct-trip-state`
- **Status:** Complete

## Outcome and scope

A committed itinerary revision must never be hidden by an older terminal Redis
result. PostgreSQL remains the authorization boundary and source of truth;
Redis remains optional, rebuildable acceleration.

The sprint:

- require a cached terminal response to match the authorized PostgreSQL job ID,
  version, and status before it can be returned;
- write explicit versions in worker terminal payloads;
- refresh or invalidate terminal cache entries after committed revisions,
  copies, trip deletion, and account deletion;
- add focused regressions for stale cache, Redis failure, worker completion, and
  mutation-boundary cache handling;
- update the committed API contract only if the public schema changes.

Campaign-site changes, speculative features, pagination, and broad refactors are
out of scope. An adjacent foundation issue will be taken only if this outcome is
fully verified first.

The primary outcome and its failure-state hardening consumed the sprint. No
adjacent feature was added.

## Risks and controls

- **Post-commit Redis failure:** cache maintenance is best effort; version-aware
  reads still return durable state.
- **Worker/revision race:** a late v1 cache write may follow a v2 commit, so
  invalidation is cleanup rather than the correctness mechanism.
- **Deletion residue:** bounded cleanup is attempted after the database commit,
  but a failed or racing late writer can leave an orphan until TTL; PostgreSQL
  authorization prevents that cache document from restoring access.
- **Compatibility:** legacy cache entries without `version` continue to parse as
  v1 but cannot supersede a newer database version.

## Acceptance criteria

- A v2+ PostgreSQL result wins over a stale v1 Redis terminal result.
- A matching terminal cache entry remains usable, while malformed, mismatched,
  or unavailable Redis data falls back safely to PostgreSQL.
- Worker success and failure payloads carry the durable version.
- Revision, duplicate/catalog-copy, trip-delete, and account-delete boundaries
  perform cache maintenance only after successful commit.
- Backend lint/tests, OpenAPI drift, Alembic static upgrade, Compose validation,
  iOS generation/build/tests, and Git diff checks pass or have a documented
  environment blocker.

## Validation commands

```bash
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m ruff check backend tests scripts
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m pytest
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python scripts/export_openapi.py --check
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/python -m alembic upgrade head --sql > /dev/null
docker compose config --quiet
(cd ios && xcodegen generate)
xcodebuild -project ios/Itinera.xcodeproj -scheme Itinera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
git diff --check
```

## Validation status

Completed July 13, 2026:

- Ruff passed for `backend`, `tests`, and `scripts`.
- 142 backend tests passed, up 11 from the 131-test baseline.
- OpenAPI drift check passed; the existing public contract required no change.
- Alembic reported one head (`f61d2a8b9c43`) and emitted the complete static
  upgrade successfully.
- Docker Compose configuration and `git diff --check` passed.
- XcodeGen 2.45.4 regeneration was deterministic.
- iOS Debug and Release simulator builds passed on Xcode 26.6; the Release app
  contained the injected HTTPS API URL and no ATS exception.
- All 70 iOS tests passed on an iOS 26.5 iPhone 17 Pro simulator.

Backend commands ran locally on Python 3.11.15 because Python 3.12 was not
installed on this host; the repository CI target remains Python 3.12.
