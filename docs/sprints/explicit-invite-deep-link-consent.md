# P32 — Explicit invite deep-link consent

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

Opening an `itinera://invite/<token>` link no longer changes a traveler's
collaboration membership immediately. The app accepts only a bounded URL-safe
invite token, presents an explicit confirmation explaining the owner-visible
collaborator effect, and sends the acceptance request only after the traveler
chooses **Join trip**. Selecting **Not now** makes no request.

## Boundary

This protects the external deep-link entry point. A traveler who pastes a token
into the in-app Trip Tools flow still explicitly presses its existing Join
button. The server remains authoritative for token validity, expiry, one-time
acceptance, and itinerary ownership; this client confirmation does not reveal
invite metadata before authorization.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraUITests/ItineraUITests/testInviteDeepLinkRequiresExplicitConfirmation test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
