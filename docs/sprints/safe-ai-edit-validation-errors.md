# P29 — Safe AI-edit validation errors

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

Malformed AI-edit output can no longer place Pydantic validation text or model
content in a client-visible `422`. The route returns a stable, actionable
message while retaining the original exception as the private cause. The editor
also stops embedding individual model validation details in its public error.

## Boundary

This covers invalid edit output. Provider failures remain a generic `503`, and
revision conflict responses intentionally expose only the current version and a
stable message. General API error normalization and support correlation remain
separate work.

## Verification

- `ENV=test OTEL_SDK_DISABLED=true venv/bin/python -m pytest -q tests/test_editor.py tests/test_trip_platform.py -k 'ai_edit or editor_invalid_day'` — 5 passed
- `git diff --check`
