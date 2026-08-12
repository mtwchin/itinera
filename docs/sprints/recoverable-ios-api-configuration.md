# P31 — Recoverable iOS API configuration

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

A missing or malformed `ItineraAPIBaseURL` no longer terminates the app at
launch. The app now presents an accessible, non-sensitive configuration failure
screen that directs the traveler to install a current build. Release builds
still require an HTTPS API address, and the existing Xcode pre-build guard
continues to reject an unset production URL before archive/build completion.
A Debug-only UI-test fixture renders the failure state without needing a
malformed signed build.

## Boundary

This is a failure-state guard, not a release configuration replacement. The
app cannot repair a compiled build configuration, and the approved production
endpoint, signing, archive/export, and TestFlight validation remain release
operations work. Debug localhost overrides keep their current development-only
behavior.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIConfigurationTests test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraUITests/ItineraUITests/testInvalidConfigurationShowsRecoveryStateInsteadOfCrashing test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
