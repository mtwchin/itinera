# Sprint P4 — Seven-night beta generation cap

**Started:** July 16, 2026  
**Status:** Locally validated; awaiting intentional review and integration  
**Scope:** New generation request limit, iOS range-selection limit, persisted
policy compatibility, API contract, and tests.

## Decision

The initial beta accepts trips of one through seven nights. This turns the
existing readiness recommendation into an enforced product boundary: it bounds
LLM response size and spend exposure while the team establishes a cost model,
quality evaluation, and a longer-trip generation strategy.

## Contract and rollout

| Request class | Policy | Maximum nights | Behavior |
|---|---:|---:|---|
| Newly accepted job | v2 | 7 | API rejects longer requests with `422`; iOS disables submission and explains the limit. |
| Job accepted before rollout | v1 | 30 | Worker honors the contract that was in force when the job was accepted. |
| Legacy local draft over cap | v2 on resubmission | 7 | Date picker retains arrival, clears departure, and requires a valid new range. |

`itineraries.generation_policy_version` is an additive, non-null column. The
upgrade defaults existing rows to v1; application-created jobs are explicitly
v2. The worker passes that persisted version into request validation, so a
future policy does not silently reinterpret queued work. Unknown future values
fail closed to the current seven-night cap. The migration registers its schema
lineage and can roll back by removing the version column after the usual
application rollback window.

## Product and accessibility behavior

- The range picker communicates the seven-day beta limit before selection and
  gives a specific error after an over-limit departure is tapped.
- Form validity uses the same shared range predicate as the picker, preventing
  old local drafts from reaching the API with a known-invalid duration.
- Server validation remains authoritative for all clients and direct API use.

## Evidence and remaining work

- Full backend lint and test evidence is green: Ruff passed and all **245
  runnable tests passed** (16 real-infrastructure tests skipped locally).
- XcodeGen and the full Debug simulator suite passed on iPhone 17 Pro / iOS
  26.5 after the iOS range-cap change.
- Static PostgreSQL upgrade generation confirms the column and schema-lineage
  registry entry for migration `50ce64cadfa5`.
- The cap does not provide a provider-call ledger, token accounting, daily
  dollar ceiling, or long-trip strategy. Those remain the next cost-control
  sprint and are prerequisites for relaxing the cap.
