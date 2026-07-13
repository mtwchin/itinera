from pathlib import Path


def test_openai_key_is_scoped_to_generation_worker():
    blueprint = Path("render.yaml").read_text(encoding="utf-8")

    assert blueprint.count("- key: OPENAI_API_KEY") == 1
    worker = blueprint.split(
        "  - type: worker\n    name: itinera-worker", maxsplit=1
    )[1].split("  - type: worker\n    name: itinera-outbox", maxsplit=1)[0]
    assert "- key: OPENAI_API_KEY" in worker
