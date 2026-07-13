"""Low-cardinality API-owned admission, lease, and readiness metrics."""

from prometheus_client import Counter

_admission_decisions = Counter(
    "itinera_admission_decisions_total",
    "Atomic API admission decisions and fail-closed outcomes.",
    ("policy", "outcome"),
)
_stream_lease_events = Counter(
    "itinera_stream_lease_events_total",
    "Distributed itinerary stream lease lifecycle events.",
    ("event",),
)
_readiness_checks = Counter(
    "itinera_readiness_checks_total",
    "Uncached API readiness dependency check results.",
    ("check", "result"),
)


def record_admission(policy: str, outcome: str) -> None:
    _admission_decisions.labels(policy=policy, outcome=outcome).inc()


def record_stream_lease(event: str, amount: int = 1) -> None:
    if amount > 0:
        _stream_lease_events.labels(event=event).inc(amount)


def record_readiness(check: str, result: str) -> None:
    _readiness_checks.labels(check=check, result=result).inc()
