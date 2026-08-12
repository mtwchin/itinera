# Spend-admission decision record

**Status:** Awaiting product/finance approval. Do not populate with estimates.

This record is the required input to the pending NXT-008 spend-admission
implementation. Each deployed model needs a dated, approver-owned entry; a
provider/model change is a new entry, not an implicit continuation.

| Field | Required decision |
|---|---|
| Effective date and owner | Who approved the rate and when it expires or is reviewed |
| Provider and exact model | Must match the configured production provider/model |
| Currency and unit | Currency plus input/output price per one million tokens |
| Maximum reservation | Maximum currency units reserved before one generation or edit request starts |
| Principal daily hard limit | Maximum reserved/actual spend for one authenticated principal/device day |
| Global daily hard limit | Maximum reserved/actual spend for the production day |
| Warning thresholds | Percentages and alert destinations before each hard limit |
| Unknown-usage policy | Whether a completed provider call without valid usage is blocked, charged at its reservation, or escalated |
| Reconciliation policy | How reservations release/settle after success, failure, timeout, lease loss, and a crash after a paid call |
| Emergency action | Owner and procedure for immediate admission closure |

## Required acceptance evidence

- The values are approved by product and finance/security, with a review date.
- Staging proves atomic global/principal reservation, bounded release, warning
  alerts, kill switch, and fail-closed behavior when the coordinator is absent.
- A provider/model or pricing change cannot deploy until its corresponding
  dated record is reviewed and configured.
- Operator documentation states that current token ledgers are provider-reported
  facts, not settled invoices, and preserves the known paid-call/crash window.

No code in this repository may infer or backfill an absent rate from a provider
name, model name, or a public pricing page.
