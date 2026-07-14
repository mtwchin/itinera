from unittest.mock import MagicMock, patch

from backend.observability.platform_metrics import (
    record_admission,
    record_readiness,
    record_stream_lease,
)


def test_admission_metric_uses_only_fixed_policy_and_outcome_labels():
    child = MagicMock()
    with patch(
        "backend.observability.platform_metrics._admission_decisions"
    ) as counter:
        counter.labels.return_value = child

        record_admission("generation", "global_denied")

    counter.labels.assert_called_once_with(
        policy="generation",
        outcome="global_denied",
    )
    child.inc.assert_called_once_with()


def test_stream_lease_metric_records_positive_aggregate_without_labels():
    child = MagicMock()
    with patch(
        "backend.observability.platform_metrics._stream_lease_events"
    ) as counter:
        counter.labels.return_value = child

        record_stream_lease("stale_reclaimed", 3)
        record_stream_lease("stale_reclaimed", 0)

    counter.labels.assert_called_once_with(event="stale_reclaimed")
    child.inc.assert_called_once_with(3)


def test_readiness_metric_uses_only_fixed_check_and_result_labels():
    child = MagicMock()
    with patch(
        "backend.observability.platform_metrics._readiness_checks"
    ) as counter:
        counter.labels.return_value = child

        record_readiness("postgres", "timeout")

    counter.labels.assert_called_once_with(check="postgres", result="timeout")
    child.inc.assert_called_once_with()
