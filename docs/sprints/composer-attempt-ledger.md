# Sprint P7 — Composer attempt ledger

**Started:** July 16, 2026  
**Status:** Validated against real local PostgreSQL; awaiting intentional review and integration  
**Scope:** Durable, privacy-safe accounting of every LLM composer attempt.

## Delivered contract

Each worker invocation now collects one record per composer attempt, including
failed retries, and writes all records in the same terminal database transaction
as the itinerary status. Existing `agent_runs` rows carry only:

- `agent`: `itinerary_composer`;
- 1-based attempt number;
- provider, configured model, and immutable prompt-version identifier;
- bounded elapsed latency in milliseconds.

Prompt text, trip requests, accommodation details, generated itinerary content,
raw provider payloads, tokens, and exception text are deliberately not written
to the ledger. Failed jobs retain the same public-safe failure contract from P3.
If a terminal write loses its execution lease, neither terminal state nor ledger
rows are committed.

OpenAI, Groq, and Anthropic SDK automatic retries are disabled. Those clients
would otherwise make additional paid calls inside one application-level
composer attempt, outside the durable ledger. The pipeline's bounded retry
loop is now the explicit retry budget for those providers.

## Why this is not the complete cost-control gate

This starts the provider-call count/latency/model/prompt-version ledger required
by NXT-008. It does not yet record provider-reported token usage or an estimated
cost, and therefore cannot enforce per-job or daily dollar admission ceilings.
Those need provider-specific usage extraction, product-approved rate cards,
reservation/reconciliation semantics, alerts, and a failure policy for unknown
usage. The seven-night P4 cap remains the current cost exposure boundary.

## Focused evidence

- Pipeline retry tests prove each attempt—including a failed semantic retry—is
  recorded once with no user request or result payload.
- Worker tests prove the callback is supplied and accumulated records flow to
  terminal persistence on both success and failure paths.
- A real PostgreSQL integration test proves terminal state and its `agent_runs`
  row commit together, and that a stale lease cannot append another row.
- Ruff passed; all **249 unit tests** and all **17 opt-in PostgreSQL/Redis
  integration tests** passed locally. Docker Compose configuration and OpenAPI
  drift checks also passed.

This proves the persistence transaction locally, not deployment operation. CI
must run the same integration lane and production still needs monitoring,
retention, and a documented recovery runbook.

## Follow-up reliability boundary

The current OpenAI Responses API schema exposes usage but does not establish a
supported request idempotency key for this endpoint. Do not add an unverified
header and claim duplicate-billing protection. The remaining crash window is
therefore still release-gated work: define a provider-supported recovery or
bounded duplicate-cost policy, then test it against the selected production
provider.
