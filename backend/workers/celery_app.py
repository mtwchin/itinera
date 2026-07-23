from celery import Celery
from opentelemetry.instrumentation.celery import CeleryInstrumentor

from backend.config import get_settings

_settings = get_settings()

celery_app = Celery(
    "itinera",
    broker=_settings.celery_broker_url,
    backend=_settings.celery_result_backend,
    include=["backend.workers.tasks"],
)

celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    task_acks_late=True,
    worker_prefetch_multiplier=1,
    task_default_retry_delay=5,
    task_default_max_retries=3,
    broker_transport_options={
        "visibility_timeout": _settings.celery_broker_visibility_timeout_seconds
    },
    result_backend_transport_options={
        "visibility_timeout": _settings.celery_broker_visibility_timeout_seconds
    },
    # The task decorator receives the same explicit limits. Keeping them in
    # app configuration makes the bound visible to Celery inspection tooling.
    task_soft_time_limit=_settings.itinerary_job_soft_time_limit_seconds,
    task_time_limit=_settings.itinerary_job_time_limit_seconds,
    task_store_errors_even_if_ignored=False,
    # Matches the historical Celery default. Keeping it explicit makes the
    # one-time legacy result-key drain window operationally auditable.
    result_expires=24 * 60 * 60,
)

CeleryInstrumentor().instrument()
