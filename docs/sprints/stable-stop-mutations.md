# Sprint P41 — Stable stop-ID mutation targets, client mutation IDs, and conflict UX

**Sprint:** P41  
**Branch:** `codex/social-itinerary-sources`  
**Commit:** `a5a5dd2`  
**Status:** Locally validated

---

## Problem

Three correctness gaps in the revision system:

1. **Index fragility**: `RemoveActivity`, `ReplaceActivity`, and
   `ReorderActivity` target stops by array index. After a concurrent edit the
   same index may point to a different stop — silently mutating the wrong one.
2. **No idempotency key**: A network retry re-applies the same operation,
   corrupting the itinerary.
3. **Opaque 409**: The iOS client maps version conflicts to a plain error
   message with no reload path; the user is stuck.

Activity IDs are already stable (UUID5, trip-scoped, materialized in
`materialize_activity_ids()`). The upgrade targets these IDs rather than
indexes, with backward compatibility for in-flight index-only operations.

---

## Accepted outcome

1. `RemoveActivity`, `ReplaceActivity`, and `ReorderActivity` accept an
   optional `activity_id` alongside their index fields. When present, the
   server resolves the index by ID lookup before applying the operation.
2. `ItineraryRevisionCreate` accepts a nullable `mutation_id: UUID`. The
   server deduplicates by storing the key in `itinerary_revisions` with a
   unique index; a second submission with the same key returns the cached
   revision.
3. A version conflict returns `{"code": "version_conflict", "current_version":
   N}` in the 409 body. The iOS client shows a "Trip Updated Elsewhere" sheet
   with **Reload** (fetches current state) and **Discard**.

---

## Delivery

### Backend

**`backend/schemas/trips.py`** — `activity_id` added to `RemoveActivity`,
`ReplaceActivity`, `ReorderActivity` (each requires at least one of
`activity_id` or the index field via `@model_validator`). `mutation_id:
uuid.UUID | None` added to `ItineraryRevisionCreate`.

**`backend/db/models.py`** — `mutation_id: UUID | None` column on
`ItineraryRevision` with unique index (nulls are distinct in PostgreSQL).

**`backend/db/repo.py`** — `_resolve_activity_index()` helper prefers ID
lookup over index; `revise_itinerary()` accepts `mutation_id` and returns the
cached revision on duplicate before acquiring the row lock.

**`backend/routers/trips.py`** — 409 body updated to structured
`{"code": "version_conflict", "message": ..., "current_version": N}`.

**`alembic/versions/a3e7c1f9b204_revision_mutation_id.py`** — adds
`mutation_id` column with unique index on `itinerary_revisions`.

### iOS

**`TripPlatformModels.swift`** — `activityId: String?` on remove/reorder/
replace operations; `mutationId: String?` on `ItineraryRevisionCreate`.

**`APIClient.swift`** — `reviseTrip` accepts `mutationId: String`.

**`AppState.swift`** — threads `mutationId` through to `apiClient.reviseTrip`.

**`TripEditorView.swift`** — generates `UUID().uuidString` per submission,
passes `activityId` from `Activity.activityId`, catches 409
`version_conflict`, shows conflict sheet with Reload and Discard actions.

---

## Acceptance criteria

| Criterion | Verified |
|---|---|
| ID-based remove/replace/reorder targets correct stop when indices shift | ✓ |
| `mutation_id` deduplication returns same `to_version` on retry | ✓ |
| 409 body contains `code` and `current_version` | ✓ |
| Schema rejects operations with neither `activity_id` nor index | ✓ |
| Index-only operations remain backward-compatible | ✓ |
| All backend tests pass | ✓ |
