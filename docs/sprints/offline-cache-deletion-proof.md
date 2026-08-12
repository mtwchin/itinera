# P25 — Offline completed-trip deletion proof

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The completed-trip cache already removes its protected file and in-memory
snapshot when `AppState.clearDownloadedTripData()` runs. P25 adds a regression
test that seeds a completed offline itinerary, loads it into published app
state, clears downloaded data, and proves both the visible cache and reloaded
disk cache are empty. A second regression exercises `deleteMyData()` through a
server-confirmed `204`, then proves the completed cache, local stop progress,
saved trip draft, and locked-stop selections are gone while unrelated
preferences remain. It also proves queued job and submission records are
empty after the deletion cleanup. The server-confirmed deletion deliberately
retains the existing credentials only until all device-local cleanup completes;
then it removes them and rotates the device-scoped installation identifier
before a new guest account can be created. A paired regression proves rejected
deletion leaves account state intact, while an expired-session regression
refreshes only the existing account and never creates a guest as a deletion
side effect.

## Boundary

This directly covers the completed itinerary cache, local stop progress, and
draft/lock preferences, plus queued jobs and submissions. Account deletion
also clears credentials and rotates the installation identifier after local
cleanup succeeds. Notifications and the complete user-facing flow still need
end-to-end UI scenarios. A Keychain-finalization failure is surfaced through
the same explicit retry instruction as a failed local-file cleanup; its delete
order preserves the replay credential on any partial failure.

## Verification

- `xcodegen generate --spec ios/project.yml --project ios`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py tests/test_trip_platform.py -k delete_my_data` — 16 passed
- `git diff --check`
