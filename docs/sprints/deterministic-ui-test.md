# P24 — Deterministic iOS UI-test launch gate

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The generated iOS scheme now includes an `ItineraUITests` target. Its first
test launches the existing Debug itinerary fixture through
`ITINERA_DEMO_SCREEN=itinerary`, verifies the navigation title and fixture day
theme, and requires no backend, identity, location permission, or network.

This turns the deterministic fixture into an actual XCUITest launch contract
and makes CI execute it through the existing scheme test command.

## Boundary

This is the initial deterministic UI-test foundation, not full core-loop
coverage. Create/kill/offline/resume/success/auth-recovery/deletion flows still
need isolated UI scenarios and fixtures before Gate C.
