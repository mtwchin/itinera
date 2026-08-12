# P28 — Generation accessibility and identity recovery state

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The generation spinner is a single VoiceOver element with a changing accessible
value for the current generation stage and an `updatesFrequently` trait. The
motion animation continues to honor Reduce Motion.

When refresh-token recovery is required, the generation screen now explains
that the saved trip remains on the device and provides a Back to Trips action
instead of offering a futile retry. Terminal and transient failures retain their
existing distinct actions.

## Boundary

This improves the foreground generation state only. Full VoiceOver traversal,
Dynamic Type screenshots, localization, and an explicit identity-recovery UI
remain NXT-013/NXT-016 work.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests test`
- `git diff --check`
