# P36 — Required session principal

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

iOS now treats `user_id` as required in every issued or refreshed session
response. A missing or malformed principal identifier rejects the response
before any credentials are stored, so a new client cannot recreate unscoped
private state. The only backward-compatible path is decoding an already-saved
legacy Keychain record that predates principal persistence.

## Boundary

This enforces the existing API session contract at the client boundary. It does
not complete the D2 migration of every local store to a principal namespace;
that work still requires identity bootstrap before publishing offline state.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests -only-testing:ItineraTests/TripMutationAPIClientTests -only-testing:ItineraTests/AuthCredentialsTests test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py` — 40 passed
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
