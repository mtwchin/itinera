# Sprint P9 — Server-authoritative AI consent

**Started:** July 16, 2026  
**Status:** Validated against real local PostgreSQL; awaiting intentional review and integration  
**Scope:** Require a current, auditable consent choice before any hosted AI
generation or refinement request.

## Delivered contract

Consent is now an append-only, principal-scoped `ai_consent_events` ledger.
Each event contains only the user ID, disclosure version, action (`granted` or
`withdrawn`), and recorded time. It deliberately does not store itinerary
details, request text, provider responses, or credentials.

`POST /api/v1/auth/ai-consent` accepts only the current disclosure version and
records a grant. `DELETE /api/v1/auth/ai-consent` records a withdrawal. Initial
itinerary generation and AI itinerary edits check that the latest event for the
current version is a grant before creating a job or selecting an AI provider;
otherwise they return `403 ai_consent_required`.

The iOS disclosure sheet now persists the server record before enabling local
UI state or submitting a trip. A failed grant or withdrawal remains visible and
does not silently update local consent state.

Account deletion prelocks consent-event rows with the existing audited child
writer families and removes them through the user ownership cascade. This keeps
consent audit data scoped to the principal and avoids a new writer/deletion
race.

## Explicit boundary

The current iOS disclosure names the default hosted provider, OpenAI. Before a
non-OpenAI provider is selected for production, product/legal must publish and
version provider-specific disclosure, subprocessors, retention, deletion, and
support copy. This enforcement gate does not make that approval optional.

## Focused evidence

- API tests prove missing server consent prevents job creation; grants and
  withdrawals create the intended auditable events; stale disclosure versions
  are rejected.
- Trip-management tests prove AI edits fail before itinerary lookup/provider
  selection when consent is absent.
- The opt-in PostgreSQL/Redis lane records grant then withdrawal and verifies
  the server’s current-consent decision changes from true to false; it also
  proves account deletion removes the principal's consent events.
- iOS API tests prove both requests are authenticated and the grant carries the
  shared disclosure version.
- Ruff, OpenAPI drift, Docker Compose configuration, whitespace, and static
  migration checks passed. All **253 unit tests**, **18 opt-in
  PostgreSQL/Redis integration tests**, and **92 iOS simulator tests** passed
  locally.
