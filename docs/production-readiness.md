# Production readiness contract

This document turns "scalable" into a measurable launch target. The numbers
are an initial engineering envelope, not a demand forecast; they must be
revisited with product analytics after TestFlight.

Implementation status, current contradictions, and the ordered completion
backlog are tracked in [next-completion-plan.md](next-completion-plan.md).

## Version 1 product scope

Version 1 includes anonymous onboarding, optional Sign in with Apple recovery,
trip creation, recoverable itinerary generation, offline saved trips, Today
mode, day-by-day maps and live travel legs, manual itinerary refinement,
sharing, trip tools, private invite links, and account/data deletion. Real-time
collaborative editing, a social feed, Android, and multi-region writes are
explicitly out of scope.

## Initial capacity envelope

- 100,000 monthly active users and 10,000 daily active users.
- 2,000 concurrently active mobile sessions at peak.
- 100 non-generation API requests per second at peak.
- 5 new generation jobs per second for a five-minute burst.
- A load-test target of 10 times expected read traffic and 2 times expected job
  submission traffic, using deterministic fake provider adapters.

External provider load is tested separately and may never exceed contracted
quotas or the configured spend ceiling.

## Service-level objectives

- API availability: 99.9% per calendar month, excluding planned maintenance.
- Non-generation API latency: p95 below 300 ms and p99 below 750 ms.
- Job acceptance latency: p95 below 500 ms.
- Accepted jobs reaching a terminal state: at least 98% within 120 seconds when
  required providers are healthy.
- Queue age: oldest ready job below 30 seconds at the designed peak.
- Duplicate paid generations caused by client or queue retries: zero.
- Crash-free iOS sessions: at least 99.8% during staged rollout.

## Release gates

- Authorization tests prove that one principal cannot read or stream another
  principal's itinerary.
- Repeating a create request with the same idempotency key and body returns the
  original job; changing the body returns a conflict.
- A broker outage leaves a dispatchable outbox record rather than an orphaned
  job.
- Killing a worker during generation does not create two terminal itineraries.
- Restoring Postgres from a point-in-time backup is exercised in staging.
- Provider timeouts, rate limits, invalid responses, and partial outages have
  explicit user-visible outcomes and bounded retries.
- The app can be killed after submission, relaunched offline, and later recover
  the pending job without charging for a second generation.
- Accessibility checks cover VoiceOver, Dynamic Type, reduced motion, and
  minimum supported screen sizes.

## Cost guardrails

Every job records provider request counts, model and prompt version, input and
output tokens, latency, cache hits, and estimated cost. Production requires a
product-approved maximum cost per completed itinerary, per-account quotas, a
global daily spend alert, and an automatic admission-control ceiling.
