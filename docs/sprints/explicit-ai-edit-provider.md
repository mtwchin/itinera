# P12 — Explicit AI-edit provider and budget

**Status:** locally validated; awaiting intentional review and integration.

## Outcome

AI itinerary edits now use only `ITINERARY_COMPOSER_PROVIDER`, the same
explicit provider selected for generation. The old "first configured
credential" fallback could silently send edit data to a different vendor than
the selected generation provider.

The API-owned `ITINERARY_EDITOR_MAX_OUTPUT_TOKENS` setting defaults to 8,000
and is passed to every supported editor provider. OpenAI and Groq use
`max_completion_tokens`; Anthropic uses `max_tokens`; Gemini uses
`max_output_tokens`. OpenAI's official API reference describes
`max_completion_tokens` as an upper bound that includes visible and reasoning
tokens; the Responses API uses `max_output_tokens`. The selected OpenAI,
Groq, and Anthropic SDK clients also use the 90-second timeout and disable
automatic retries, so one edit request cannot create invisible additional paid
calls.

Provider failures now produce one generic 503 response. Detailed exceptions
stay in private logs rather than appearing in the API response.

## Boundary

This is a per-edit output exposure bound, not a dollar ceiling. A production
rate card, daily reservation/reconciliation, and formal spend admission remain
open under NXT-008. The 8,000-token default must be measured against the
approved editor quality evaluation before a broader rollout.

## Evidence

- Unit tests prove explicit provider selection, no credential fallback,
  disabled SDK retries, and output caps for OpenAI and Anthropic.
- A route test proves a provider failure is returned as a generic 503 without
  its detail.
- Render scopes the editor ceiling to the API process, which owns AI edits.
- Render provides the selected OpenAI edit credential to the API as well as the
  generation worker; otherwise the synchronous edit endpoint would always fail
  after consent despite a healthy worker. Discovery/maps credentials remain
  worker-only.
- Production `/readyz` rejects an API process with no usable selected editor
  provider, output bound, or request timeout rather than presenting a healthy
  deployment whose edits all fail at runtime.
