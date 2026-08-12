# Sprint P8 — Provider-reported token ledger

**Started:** July 16, 2026  
**Status:** Validated against real local PostgreSQL; awaiting intentional review and integration  
**Scope:** Record sanitized provider-reported token counts for every completed
composer attempt.

## Delivered contract

The P7 attempt record now includes a `usage` object inside its existing
privacy-safe provider-call metadata:

- `source: provider` with any input and/or output token counts supplied by the
  provider; or
- `source: unavailable` if no valid provider response usage is available.

Ollama (`prompt_eval_count`/`eval_count`), Anthropic and OpenAI Responses
(`input_tokens`/`output_tokens`), Groq (`prompt_tokens`/`completion_tokens`),
and Gemini (`prompt_token_count`/`candidates_token_count`) are normalized to
the same `input_tokens` and `output_tokens` keys. Counts must be non-negative
integers; booleans, negative values, unrecognized fields, prompts, responses,
and raw provider payloads are never persisted. A semantic-validation failure
after a provider response still retains that response's reported usage.

No migration is required: `agent_runs.tool_calls` already holds the
per-provider-call, privacy-safe metadata introduced in P7.

## Explicit boundary

This is usage reconciliation, not spend admission. It intentionally does not
invent token counts, provider pricing, or dollar estimates. Per-job,
per-principal, and daily dollar ceilings require product-approved, versioned
rate cards; atomic reservation and reconciliation; alert thresholds; an
unknown-usage failure policy; and staging exercises. The seven-night P4 cap is
still the current exposure boundary.

## Focused evidence

- Composer tests cover Ollama usage extraction and reject invalid provider
values before they reach the ledger.
- OpenAI, Groq, and Anthropic automatic SDK retries are disabled so they cannot
  create unledgered provider calls inside one recorded composer attempt.
- Pipeline retry tests prove each attempt records sanitized provider usage with
  its provider/model/prompt metadata.
- Ruff, OpenAPI drift, Docker Compose configuration, and whitespace checks
  passed locally. All **249 unit tests** and **17 opt-in PostgreSQL/Redis
  integration tests** passed, including durable preservation of the usage
  metadata in the terminal transaction.
