"""Provider errors must be actionable without exposing provider internals."""

from unittest.mock import MagicMock, patch

import pytest
from openai import OpenAIError

from backend.agents.composers import ComposerError, OpenAIComposer
from tests.test_composers import PLACES, REQUEST


def test_openai_authentication_failures_are_not_reported_as_invalid_itineraries():
    provider_error = OpenAIError("sensitive provider error")
    provider_error.status_code = 401
    client = MagicMock()
    client.responses.parse.side_effect = provider_error

    with patch("backend.agents.composers.OpenAI", return_value=client):
        composer = OpenAIComposer("test-key", "gpt-4o-mini")

    with pytest.raises(
        ComposerError,
        match="OpenAI authentication or model access failed",
    ) as exc_info:
        composer.compose(REQUEST, PLACES)

    assert "sensitive provider error" not in str(exc_info.value)
