"""Apple Push Notification Service (APNs) client.

Sends alert notifications to registered iOS devices using JWT-based bearer
authentication (ES256, no certificates required). Requires HTTP/2 support
from the ``h2`` package (installed alongside ``httpx[http2]``).

All APNs configuration is optional. When any required setting is absent the
dispatch is silently skipped so development environments without APNs keys do
not fail generation jobs.
"""

from __future__ import annotations

import time

import httpx
import jwt
from loguru import logger

from backend.config import Settings


def _apns_host(env: str) -> str:
    if env == "production":
        return "https://api.push.apple.com"
    return "https://api.sandbox.push.apple.com"


def _make_provider_token(settings: Settings) -> str:
    """Return a short-lived ES256 JWT for APNs bearer auth."""
    return jwt.encode(
        {"iss": settings.apns_team_id, "iat": int(time.time())},
        settings.apns_key_p8,
        algorithm="ES256",
        headers={"kid": settings.apns_key_id},
    )


def _apns_configured(settings: Settings) -> bool:
    return bool(
        settings.apns_key_id
        and settings.apns_key_p8
        and settings.apns_team_id
    )


def send_trip_ready_notification(
    *,
    device_tokens: list[str],
    job_id: str,
    title: str | None,
    settings: Settings,
) -> None:
    """Dispatch an APNs alert to each device token (best-effort, fire-and-forget).

    Called synchronously from the Celery worker process after a successful
    generation. Failures are logged but never re-raised so the worker result is
    unaffected.
    """
    if not device_tokens:
        return
    if not _apns_configured(settings):
        logger.debug("APNs not configured, skipping push for job {}", job_id)
        return

    trip_title = (title or "").strip()
    body = (
        f"{trip_title} is ready to explore." if trip_title
        else "Open Itinera to explore your new route."
    )
    payload = {
        "aps": {
            "alert": {
                "title": "Your trip is ready",
                "body": body,
            },
            "sound": "default",
        },
        "itinera_destination": "trip",
        "itinera_job_id": job_id,
    }

    host = _apns_host(settings.apns_env)
    try:
        token = _make_provider_token(settings)
    except Exception:
        logger.exception("APNs JWT signing failed for job {}", job_id)
        return

    # A single HTTP/2 connection multiplexes all requests concurrently.
    try:
        with httpx.Client(
            http2=True,
            base_url=host,
            timeout=settings.apns_request_timeout_seconds,
        ) as client:
            for device_token in device_tokens:
                try:
                    response = client.post(
                        f"/3/device/{device_token}",
                        json=payload,
                        headers={
                            "authorization": f"bearer {token}",
                            "apns-topic": settings.apns_bundle_id,
                            "apns-push-type": "alert",
                            "apns-priority": "10",
                        },
                    )
                    if response.status_code == 200:
                        logger.debug(
                            "APNs delivered for job {} token …{}",
                            job_id,
                            device_token[-6:],
                        )
                    else:
                        logger.warning(
                            "APNs rejected token …{} for job {}: {} {}",
                            device_token[-6:],
                            job_id,
                            response.status_code,
                            response.text[:200],
                        )
                except httpx.HTTPError:
                    logger.exception(
                        "APNs HTTP error for job {} token …{}",
                        job_id,
                        device_token[-6:],
                    )
    except Exception:
        logger.exception("APNs connection failed for job {}", job_id)
