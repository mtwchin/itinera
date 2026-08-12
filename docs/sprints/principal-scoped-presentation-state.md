# P40 — Principal-scoped widget and Lock Screen presentation

**Status:** Locally validated; awaiting intentional review/integration.

## Outcome

The shared widget container now exposes only the snapshot selected by an opaque
principal-derived key. The widget extension resolves that selected key from its
App Group defaults; it cannot fall back to the old unscoped snapshot key.

When production AppState first establishes a principal, it removes the legacy
widget selection, reloads the widget timeline, and ends existing Itinera Live
Activities and pending/delivered Itinera notifications before any current-trip
presentation is published. Today then saves the new snapshot and schedules
reminders only from the refreshed current-principal library. This favors
privacy over preserving presentation state across a cold launch.

## Boundary

Notification identifiers are not yet opaque-principal namespaced, but every
Itinera notification is removed during cold principal activation, deletion,
and explicit existing-library recovery. Rebuilding reminders from the current
library avoids a stale presentation surface; selective per-principal retention
would require a future ownership-tagged notification contract.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/TripWidgetSnapshotTests -only-testing:ItineraTests/TripMutationAPIClientTests test`
- The widget regression writes snapshots for two opaque keys and proves only
  the selected key is visible; clearing a non-selected key leaves the selected
  snapshot intact.
- The principal-activation regression seeds the legacy widget snapshot and
  proves activation clears it before scoped publication.
