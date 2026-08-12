# P39 — Principal-scoped drafts and locked stops

**Status:** Locally validated; awaiting intentional review/integration.

## Outcome

Trip-form drafts and locked-stop preferences now pass through `AppState`, which
activates the authenticated principal before accessing UserDefaults. The
defaults keys use the same opaque P37 scope as the core stores; the server UUID
is not written into a defaults key.

The Plan form no longer uses `@AppStorage` against a process-wide key, and the
editor no longer reads locks during initialization. Both load only after the
scoped AppState path is active. First scoped activation deletes legacy draft
and lock keys instead of making them visible to an unproven principal.

## Boundary

App Group widget snapshots, Live Activities, and notification ownership remain
unscoped. P33 clears them for deletion and explicit Apple existing-library
recovery, but a complete cold-start identity-switch design is still required
before external release.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/TripMutationAPIClientTests -only-testing:ItineraTests/LocalPrincipalScopeTests test`
- The AppState regression seeds legacy core stores, a draft, and a locked stop;
  it proves legacy values are removed and scoped draft/lock values round-trip.
- `git diff --check`
