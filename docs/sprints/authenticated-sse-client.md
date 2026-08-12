# P26 — Authenticated SSE generation progress

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

`APIClient.awaitItinerary` now opens the owner-scoped itinerary SSE endpoint
before polling. It accepts only completed `status` or `result` frames, reconnects
at most twice, and uses a dedicated 120-second resource timeout per stream.
This bounds one foreground wait to four minutes of streams and preserves most
of the existing ten-minute budget for the authoritative status-poll fallback.

A terminal stream result ends the wait immediately. The regression proves the
default policy makes exactly two nonterminal stream attempts before one
authoritative status poll. A nonterminal EOF,
transport failure, admission limit, or malformed known event falls back to the
existing authenticated status endpoint. Cancellation and an explicit auth
failure still propagate rather than creating a parallel watcher.

## Boundary

This is a foreground generation-view path, not a background SSE service. A
view task owns one `awaitItinerary` call; leaving it cancels the request and
the persisted pending-job path remains responsible for later recovery. The
backend remains the source of truth and continues to enforce its per-principal
stream lease/cap.

Identity-recovery policy, background reconnecting, server-driven progress UI,
and real-infrastructure reconnect tests remain NXT-012/NXT-013 work.

## Verification

- `xcodebuild -quiet -project ios/Itinera.xcodeproj -scheme Itinera -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ItineraTests/APIClientTests test`
- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_itinerary_stream.py` — 15 passed
- `git diff --check`
