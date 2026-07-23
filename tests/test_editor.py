from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from backend.agents import editor
from backend.schemas.itinerary import Itinerary


def _settings(**overrides):
    values = {
        "itinerary_composer_provider": "openai",
        "openai_api_key": "openai-key",
        "openai_model": "gpt-5.6-luna",
        "openai_request_timeout_seconds": 45,
        "itinerary_editor_max_output_tokens": 800,
        "anthropic_api_key": "anthropic-key",
        "anthropic_model": "claude-test",
        "gemini_api_key": "gemini-key",
        "gemini_model": "gemini-test",
        "groq_api_key": "groq-key",
        "groq_model": "groq-test",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def test_editor_uses_only_the_explicitly_selected_provider():
    generate = MagicMock()
    with patch.object(editor, "_openai_generate_fn", return_value=generate) as openai, patch.object(
        editor, "_anthropic_generate_fn"
    ) as anthropic:
        actual = editor.generate_fn_for_settings(_settings())

    assert actual is generate
    openai.assert_called_once_with(
        "openai-key",
        "gpt-5.6-luna",
        timeout_seconds=45,
        max_output_tokens=800,
    )
    anthropic.assert_not_called()


def test_editor_never_falls_back_to_a_different_provider_credential():
    with pytest.raises(RuntimeError, match="OPENAI_API_KEY"):
        editor.generate_fn_for_settings(_settings(openai_api_key=None))


def test_editor_invalid_day_error_does_not_echo_model_content():
    itinerary = Itinerary.model_validate(
        {
            "itinerary": [],
            "tips": [],
            "accommodation_info": {
                "morning_start": "09:00",
                "evening_return": "18:00",
                "transportation_tips": "Walk",
            },
            "estimated_budget": "€0",
        }
    )

    with pytest.raises(editor.AIEditorError) as exc_info:
        editor.apply_ai_edit(
            lambda _system, _user: '[{"day":1,"activities":[{"name":"private hotel"}]}]',
            itinerary,
            "Adjust the route",
            None,
        )

    assert str(exc_info.value) == "AI editor returned an invalid day object"
    assert "private hotel" not in str(exc_info.value)


def test_openai_editor_disables_retries_and_bounds_completion_tokens():
    client = MagicMock()
    client.chat.completions.create.return_value.choices = [
        MagicMock(message=MagicMock(content="[]"))
    ]
    with patch("openai.OpenAI", return_value=client) as sdk:
        generate = editor._openai_generate_fn(
            "openai-key",
            "gpt-5.6-luna",
            timeout_seconds=45,
            max_output_tokens=800,
        )
        assert generate("system", "user") == "[]"

    sdk.assert_called_once_with(api_key="openai-key", timeout=45, max_retries=0)
    assert client.chat.completions.create.call_args.kwargs["max_completion_tokens"] == 800


def test_anthropic_editor_disables_retries_and_bounds_completion_tokens():
    client = MagicMock()
    client.messages.create.return_value.content = [MagicMock(text="[]")]
    with patch("anthropic.Anthropic", return_value=client) as sdk:
        generate = editor._anthropic_generate_fn(
            "anthropic-key",
            "claude-test",
            timeout_seconds=45,
            max_output_tokens=800,
        )
        assert generate("system", "user") == "[]"

    sdk.assert_called_once_with(api_key="anthropic-key", timeout=45, max_retries=0)
    assert client.messages.create.call_args.kwargs["max_tokens"] == 800


def test_editor_attempt_metadata_is_provider_safe_and_marks_unknown_usage():
    def generate(_system: str, _user: str) -> str:
        return "[]"

    generate.provider = "openai"
    generate.model = "gpt-5.6-luna"
    generate.reported_usage = {"input_tokens": 123, "output_tokens": 456}

    record = editor.editor_attempt_metadata(generate, latency_ms=42)

    assert record == {
        "agent": "itinerary_editor",
        "step_index": 1,
        "tool_calls": [{
            "kind": "provider_call",
            "provider": "openai",
            "model": "gpt-5.6-luna",
            "prompt_version": editor.EDITOR_PROMPT_VERSION,
            "usage": {"source": "provider", "input_tokens": 123, "output_tokens": 456},
        }],
        "latency_ms": 42,
    }
