# P30 — Apple recovery local-data isolation

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

When the explicit Apple sign-in flow discovers an existing library and changes
the device to that account, Itinera now removes the prior account's downloaded
trips, stop progress, queued jobs and submissions, drafts, locked stops, and
scheduled generation notifications before it fetches the recovered library.
Unrelated app preferences remain intact. A normal Apple link for the active
account keeps local state unchanged, unless a prior recovery cleanup failed;
that case is marked locally and retried by the next explicit Apple action.
Only the backend's explicit `409 apple_account_exists` contract can activate
this recovery path; another link conflict is returned to the user unchanged.

## Boundary

This closes the local-data leak in the completed recovery path. It does not
make account recovery transactionally crash-safe across the server credential
swap and persistence of the local retry marker, nor does it implement
principal-namespaced storage or cross-device recovery verification. If local
cleanup fails, the user sees an explicit recovery-specific error instead of the
account-deletion message.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py -k apple` — 9 passed
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q` — 280 passed, 20 integration tests skipped
- `venv/bin/ruff check backend tests scripts`
- `git diff --check`
