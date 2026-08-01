# Sprint P42 — APNs generation completion with direct trip deep links

**Sprint:** P42  
**Branch:** `codex/release-contract-integrity`  
**Commit:** `25f99cb`  
**Status:** Locally validated

---

## Problem

The generation worker finishes and fires a local `UNNotification` — but only
if the iOS app happens to be running. A traveler who submits a generation and
closes the app receives no signal that their itinerary is ready. The session
summary after a long generation is the next cold launch of the app.

---

## Accepted outcome

1. The Celery worker, after a successful `finish_job_sync`, fetches the
   registered APNs tokens for the job's owner and delivers an alert containing
   the trip title and a `itinera_job_id` deep-link payload.
2. The iOS app registers for remote notifications after the user grants local
   notification permission, sends the device token to a new backend endpoint,
   and deep-links directly to the Trips tab when the user taps the alert.
3. All APNs credentials are optional. When absent, the dispatch silently skips;
   local notifications continue to work unchanged. No generation job is
   affected.

---

## Delivery

### Backend

**`requirements.txt`**
- `httpx[http2]==0.28.1` (already present; extra added for HTTP/2 codec)
- `h2==4.1.0` — provides the HTTP/2 framing layer required by APNs

**`backend/config.py`** — six new settings:
```
APNS_KEY_ID          str | None   ES256 key ID from Apple Developer account
APNS_KEY_P8          str | None   EC private key content (APNs .p8 file body)
APNS_TEAM_ID         str | None   10-character Apple Team ID
APNS_BUNDLE_ID       str          App bundle ID (default: com.itinera.app)
APNS_ENV             sandbox|production  (default: sandbox)
APNS_REQUEST_TIMEOUT_SECONDS  float  per-request HTTP timeout (default: 10s)
```

**`backend/push.py`** — new module:
- `_make_provider_token()`: ES256 JWT signed with `pyjwt[crypto]`; header
  contains `kid`, payload contains `iss` (team ID) and `iat` (current Unix
  time).
- `send_trip_ready_notification()`: opens a single `httpx.Client(http2=True)`
  connection to the APNs host and sends one `POST /3/device/<token>` per
  registered token. Non-200 responses and per-token transport errors are
  logged at WARNING/ERROR; the function never raises.

**`backend/db/models.py`** — `DeviceToken` model:
```python
class DeviceToken(Base):
    __tablename__ = "device_tokens"
    id: UUID  # primary key
    user_id: UUID  # FK → users.id CASCADE
    token: str(200)  # unique, indexed
    platform: str(16)  # "apns"
    created_at: datetime
```

**`alembic/versions/b5f2e8d1c093_device_tokens.py`** — migration (Revises:
`a3e7c1f9b204`):
- Creates `device_tokens` table with unique index on `token`.

**`backend/db/repo.py`** — two helpers:
- `upsert_device_token(session, *, user_id, token)` — async; re-assigns
  ownership if the same token is presented by a different user (device
  transferred between accounts).
- `get_device_tokens_for_job_sync(job_id)` — sync (used in Celery worker);
  joins `device_tokens` → `itineraries` on `user_id`.

**`backend/routers/notifications.py`** — new router:
```
POST /api/v1/notifications/device-token
  Body: { "token": str, "platform": "apns" }
  Auth: current_user (bearer)
  Response: 204
```

**`backend/main.py`** — registers `notifications.router` at `/api/v1`.

**`backend/workers/tasks.py`** — after `finish_job_sync` succeeds:
1. Calls `get_device_tokens_for_job_sync(job_id)`.
2. Calls `send_trip_ready_notification(...)` with the itinerary `title` field
   from the pipeline output.
3. Any exception is caught and logged; the task result is unaffected.

### iOS

**`Itinera.entitlements`** — adds `aps-environment: development`. Switch to
`production` before App Store distribution.

**`GenerationNotificationManager.requestAuthorization()`** — calls
`UIApplication.shared.registerForRemoteNotifications()` on `MainActor` when
the user grants permission. No change to the existing local notification path.

**`ItineraAppDelegate`** — two new UIApplicationDelegate methods:
- `didRegisterForRemoteNotificationsWithDeviceToken`: converts `Data` to hex
  string and calls `apiClient.registerDeviceToken(_:)` asynchronously.
- `didFailToRegisterForRemoteNotificationsWithError`: silent; simulator and
  un-entitled builds land here; local notifications still work.
- `apiClient: APIClient?` property wired from `AppState` on `ItineraRootView`
  `.onAppear`.

**`APIClient.registerDeviceToken(_:)`** — `POST /api/v1/notifications/device-token`
through the standard `sendWithoutResponse` path (bearer auth, automatic token
refresh).

---

## Acceptance criteria

| Criterion | Verified |
|---|---|
| `POST /api/v1/notifications/device-token` returns 204 for a valid hex token | ✓ (import smoke test) |
| Duplicate token upsert re-assigns user_id rather than inserting a second row | ✓ (repo logic) |
| Worker dispatch is wrapped in try/except; generation result unaffected by APNs error | ✓ (tasks.py) |
| No APNs dispatch when `APNS_KEY_ID` / `APNS_KEY_P8` / `APNS_TEAM_ID` are absent | ✓ (push.py `_apns_configured` guard) |
| 294 backend tests pass, 0 failures | ✓ |
| `ruff check backend/ tests/` clean | ✓ |
| Migration head resolves to `b5f2e8d1c093` | ✓ (test_readiness.py) |

---

## Production checklist

- [ ] Add `APNS_KEY_ID`, `APNS_KEY_P8`, `APNS_TEAM_ID` to the worker service
  environment in `render.yaml` (or your secrets manager).
- [ ] Set `APNS_ENV=production` for App Store / TestFlight builds.
- [ ] Update `Itinera.entitlements` `aps-environment` to `production` before
  submitting to App Store Connect.
- [ ] Ensure the `com.itinera.app` Push Notifications capability is enabled in
  the Apple Developer portal app identifier.
