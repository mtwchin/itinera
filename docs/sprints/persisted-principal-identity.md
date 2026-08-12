# P35 — Persisted principal identity

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The iOS credential record now retains the normalized UUID returned as
`user_id` by guest and Apple authentication responses. Existing Keychain
records continue to decode with no principal identifier. A refresh can enrich a
legacy record, but it cannot overwrite an already bound principal with a
different server ID; that response is rejected before credentials change.

## Boundary

This establishes the durable identity input for D2. It does not yet namespace
completed trips, progress, pending work, drafts, widgets, or Live Activities by
the principal digest, and an older server response without `user_id` remains
compatible by retaining the existing value. The current backend contract does
return `user_id` on issued and refreshed sessions.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests -only-testing:ItineraTests/AuthCredentialsTests test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py` — 40 passed
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
