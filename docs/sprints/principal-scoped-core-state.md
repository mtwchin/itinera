# P38 — Principal-scoped core state bootstrap

**Status:** Locally validated; awaiting intentional review/integration.

## Outcome

Production `AppState` now establishes the authenticated principal before it
loads or writes completed trips, pending jobs, pending submissions, or stop
progress. Those four stores use the P37 opaque, versioned namespace derived
from the server UUID.

A legacy credential without a persisted principal is refreshed in place before
private state is selected; it is never replaced with a guest session. Legacy
unscoped core-store files are deleted on first scoped activation rather than
shown to an unproven principal. Every AppState path that reads or mutates these
stores activates the scope first.

## Boundary

This protects the core file-backed itinerary state. P39 additionally scopes
trip drafts and locked-stop preferences. App Group widget snapshots, Live
Activities, and notifications do not yet have per-principal namespaces.
P30/P33 clear those artifacts during explicit deletion and Apple
existing-library recovery, but cold-start identity switching still needs a
complete namespacing design before external release.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/TripMutationAPIClientTests -only-testing:ItineraTests/APIClientTests test`
- The added regression seeds all four legacy core stores, activates a
  principal, and proves legacy state is removed while the new scoped state is
  usable.
- `git diff --check`
