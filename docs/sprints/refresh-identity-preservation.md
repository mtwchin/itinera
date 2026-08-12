# P27 — Refresh identity preservation

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

An expired or rejected refresh token no longer clears credentials and silently
bootstraps a new guest account. The client preserves the existing identity,
returns an explicit recovery error, and keeps all downloaded/pending trip data
available on the device. Repeated requests remain in that recovery state rather
than switching the user to a different principal.

## Boundary

This prevents silent ownership loss; it is not a complete account-recovery
experience. The existing Apple recovery action still needs end-to-end recovery,
linking, and cross-device verification. Deliberately corrupted Keychain
credentials remain unrecoverable and are cleared before a fresh guest bootstrap.

The existing explicit Apple recovery action is documented as an identity switch
that refreshes downloaded trips, rather than promising that the prior
principal's offline cache remains visible after the switch.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_auth.py -k refresh` — 6 passed
- `git diff --check`
