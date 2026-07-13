# Sprint D1 — Adaptive Today

**Date:** July 13, 2026
**Baseline:** `ed130e8`
**Outcome:** Today communicates route timing truthfully and offers a calm,
intentional way to adjust the day when the plan no longer fits.

## User problem and journey

A traveler can see the current and next stops, but a planned start alone does
not answer when to leave. Itinera has no traveler-location state and no stored
route snapshot, so it must not imply a live-location ETA or turn schedule text
into a fabricated leave-by time.

1. Open Today and retain the planned start immediately, including offline.
2. When two relevant adjacent stops exist, check only that planned leg with
   Apple Maps in the selected transport mode.
3. If the route succeeds, show its named origin and destination, duration,
   source, check time, and route-derived leave-by. Current-route checks show an
   estimated arrival if leaving the named origin at the current clock time;
   future transit checks instead use an Apple Maps arrive-by request for the
   planned start and label that scheduled basis explicitly.
4. If the route is missing, loading, cancelled, or fails, keep the planned start
   visibly labeled as planned; never substitute it for route timing.
5. If the traveler declares “Running late?”, explain the available choices and
   link into the existing itinerary editor. Nothing changes merely by opening
   the entry point.

## Information hierarchy and copy

1. **NOW:** current stop and one-tap directions, before any timing detail.
2. Timing for the relevant next move:
   - **Route estimate:** `Leave by 11:38`,
     `ETA if leaving Alfama lanes now 11:27`, then
     `Walking · Alfama lanes → Prado · 22 min`, `Apple Maps · checked 11:05`,
     and `Planned start 12:00`. For a current-route basis, if the deadline
     passes, show `Leave now from Alfama lanes`, retain the calculated leave-by,
     and keep stating that the estimate does not use the traveler's location.
     A future transit route instead says `Arrive by 12:00` and discloses that
     Apple Maps was asked for an arrive-by route. If that calculated leave-by
     passes, tell the traveler to recheck current transit options; never claim
     the scheduled service remains catchable.
   - **Planned fallback:** `Planned time · Starts at 12:00`, followed by why a
     route-derived leave-by is unavailable.
3. User-invoked `Running late?` adjustment entry within timing.
4. Next stop, then compact day progress.
5. Full day stop list remains unchanged.

Tone stays calm and literal: “route estimate,” “planned time,” “your plan has
not changed,” and “nothing changes until you choose an edit.” Avoid “real-time,”
“optimized,” or language that claims to know where the traveler is.

## State model

| State | Presentation | Behavior |
|---|---|---|
| Planned only | Planned start text remains primary; explain missing origin, invalid schedule, or missing/invalid destination time zone | No route request when evidence is insufficient; device time zone is never substituted |
| Checking | Planned start remains visible; announce the explicit mode and named leg being checked | A newer destination/mode request invalidates the older result |
| Route available | Leave-by and current ETA or transit arrive-by are visually distinct from planned time; disclose mode, basis, leg, Apple Maps, and check time | Current-route duration powers only current ETA; future transit duration comes from a request whose `arrivalDate` is the planned start |
| Unavailable/offline | Planned start plus a non-color-only warning that live route timing is unavailable | Itinerary and progress remain intact |
| Past leave-by | Current-route basis may say `Leave now`; expired transit arrive-by basis asks the traveler to recheck | Never promise an old scheduled service remains available; adjustment remains an explicit choice |
| No stops/day complete | Preserve the existing empty/completed Today states | No route or mutation |

Route estimates are transient. They are not persisted as offline facts or
published to Widget/Live Activity surfaces in this sprint because those
surfaces do not yet preserve destination-time-zone provenance.

## Accessibility and layout

- Dynamic Type uses semantic fonts and vertical fallbacks for timing metrics,
  metadata, and Complete/Skip actions; no critical text is truncated to make a
  horizontal layout fit.
- VoiceOver receives one ordered timing summary containing state, destination,
  planned start, leave-by/ETA when derived, named leg, mode, source, and check
  time. Color never carries planned/live/error meaning alone.
- Controls retain at least 44-point targets and explicit labels/current state.
- New behavior does not depend on animation. Shared button press treatment
  honors Reduce Motion.
- Atlas paper, ink, route teal, coral wayfinding, serif headings, and semantic
  status colors remain the only visual vocabulary.

## Privacy, risks, and boundaries

- No location permission or tracking is added. The origin is a planned stop,
  named in the UI, never “your location.”
- `MKDirections` uses an explicit basis: walking, driving, and past-deadline
  transit use a current-route check; future transit requests arrival at the
  planned start. Neither basis guarantees future conditions, so basis and
  check time remain visible.
- A skipped adjacent origin makes route context uncertain and falls back to
  planned time.
- A missing or invalid itinerary destination time zone keeps the raw planned
  text visible but cannot create an absolute planned start or leave-by.
- MapKit availability, throttling, cancellation, and offline failure must not
  blank the plan or mutate it.
- The existing editor applies user-selected server revisions and already owns
  quick-refinement lock/undo behavior. The entry says, “Quick refinements won't
  remove locked stops; nothing changes until you apply an edit.” This sprint
  adds an entry point, not a second editor or automatic late-day proposal.
- Planned reminder copy and Widget placeholder truth debt remain out of scope.

## Acceptance criteria

- [x] A successful adjacent-stop route shows named origin/destination, mode,
  Apple Maps source/check time, a current ETA or transit arrive-by, and leave-by
  derived from the destination's planned start.
- [x] Future transit passes the planned start as its arrive-by date and uses
  scheduled arrive-by copy; past transit requests current-route timing.
- [x] First stop, skipped origin, malformed time, cancellation, and route
  failure visibly retain `Planned time` and never display a false leave-by.
- [x] Missing or invalid destination time zones retain raw planned text and do
  not derive an absolute start, leave-by, or route request from device time.
- [x] Stale route responses cannot replace a newer mode or stop request.
- [x] `Running late?` opens a non-mutating explanation and the existing editor;
  opening or dismissing it changes no itinerary or progress state.
- [x] Dynamic Type, VoiceOver, Reduce Motion, offline/error messaging, and a
  compact iPhone-width preview are covered by the implementation or previews.
- [x] Deterministic view-model tests pass without live MapKit calls.
- [x] XcodeGen is deterministic; all iOS tests and Debug/Release simulator
  builds pass; `git diff --check` is clean.

## Validation status

- Focused `TodayTripViewModelTests`: 19 executed, 0 failures, no live MapKit.
- Full `ItineraTests`: 87 executed, 0 failures, no build warnings.
- Debug iOS Simulator build: succeeded without warnings.
- Release iOS Simulator build: succeeded without warnings using
  `ITINERA_PRODUCTION_API_BASE_URL=https://api.example.test`; the built plist
  contains that HTTPS URL and no arbitrary-load ATS override.
- XcodeGen: two consecutive generations were byte-identical; generated project
  SHA-256 is `efff34c98be10f86530d9c95cd4ea2f85c1b958e94af11dc61ef00fd12d4f903`
  and includes both new Today sources.
- Repository checks: `git diff --check` is clean; change scope is limited to the
  iOS app, iOS tests, generated Xcode project, and this sprint document.

## Recommended next sprint

After principal-scoped offline storage and stable stop-ID/mutation-conflict
work, add route-aware running-late proposals with a readable diff, locked-stop
protection, explicit approve/reject, idempotent apply, and undo.
