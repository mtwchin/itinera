# P13 — AI-edit attempt ledger

**Status:** real-PostgreSQL validated; awaiting intentional review and integration.

## Outcome

Every AI-edit request that reaches a provider now writes one existing
`agent_runs` row. The row carries only the provider, configured model,
immutable editor prompt version, bounded latency, and provider-reported token
counts when available. Edit requests, itinerary content, generated text, raw
responses, and exception text are never stored in the ledger.

The row is committed atomically with a successful itinerary revision. A
post-call failure, no-op edit, validation rejection, or revision conflict
commits its separate attempt row before returning its public error. Provider
construction failures do not create a ledger row because no external call was
made.

## Boundary

This extends usage reconciliation to AI edits; it does not create an approved
dollar rate card, daily spend reservation, or exact-once billing guarantee.

## Evidence

- Unit tests cover provider-safe metadata and route-level persistence for a
  failed provider call without exposing its detail to the client.
- An opt-in real-PostgreSQL route test proves a failed edit returns the generic
  503 while its sanitized `agent_runs` record is committed.
