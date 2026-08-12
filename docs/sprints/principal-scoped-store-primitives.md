# P37 — Principal-scoped store primitives

**Status:** Locally validated; integrated by P38.

## Outcome

Completed trips, pending jobs, pending submissions, and stop progress now have
opaque principal-scoped store constructors. Each scope is a SHA-256 digest of a
normalized server UUID under a versioned directory, never a raw principal ID in
a path. The regression writes every private artifact for one principal and
proves another principal reads no cache, queue, submission, or progress state.

## Boundary

P38 bootstraps the persisted principal before AppState touches these stores and
deletes legacy unscoped core files rather than exposing them. Drafts, locks,
widget state, Live Activities, and notifications remain outside these four
constructors and require their own principal-namespacing work.

## Verification

- `xcodegen generate` from `ios/`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/LocalPrincipalScopeTests test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test`
- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test build`
- `git diff --check`
