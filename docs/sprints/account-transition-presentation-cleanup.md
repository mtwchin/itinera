# P33 — Account-transition presentation cleanup

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The local-account cleanup used by server-confirmed deletion and existing-library
Apple recovery now also clears the shared App Group widget snapshot, reloads its
timeline, and immediately ends all Itinera Live Activities. A new principal can
therefore not see the prior library on the Home Screen or Lock Screen while the
recovered library refreshes.

## Boundary

This removes the current global presentation state during deliberate account
transitions. It does not yet provide principal-namespaced widget or Live
Activity storage, atomic crash recovery across the credential change, or
cross-device ownership verification. Those remain D2/NXT-013 work.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/TripMutationAPIClientTests test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
