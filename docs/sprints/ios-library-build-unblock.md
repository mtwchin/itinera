# P19 — iOS trip-library build unblock

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The full iOS simulator test build exposed a Swift compiler type-check timeout in
the nested trip-library `ForEach` closure in `SavedTripsView`. The code now
uses a typed `LibrarySection` alias and a small `@ViewBuilder`
`librarySection(_:)` helper. This only separates the same heading/row view
composition into a compiler-manageable expression; grouping, navigation, and
visual behavior are unchanged.

## Evidence

- The full iPhone 17 Pro simulator test command completes successfully.
- XcodeGen regeneration produces no committed project drift.
- The Release simulator build succeeds with an injected HTTPS API URL.
- The whole-worktree whitespace audit passes.
