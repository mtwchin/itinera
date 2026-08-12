# P34 — Serialized account refresh

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

Account deletion now shares the API client's existing single-flight refresh
coordinator with all other authenticated requests. A simultaneous library read
and deletion retry therefore make one refresh-token rotation, then retry with
the same newly saved access and refresh credentials. The deletion path still
never creates a guest session, and a malformed refresh response is rejected if
it omits the required rotated refresh token.

## Boundary

This serializes refreshes inside one app process. It does not coordinate two
devices, replace server-side refresh-family replay handling, or make deletion
and local cleanup transactional. The server remains authoritative for rotation,
reuse detection, and recovery grace behavior.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py -k refresh` — 6 passed
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
