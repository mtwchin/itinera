import re
from pathlib import Path


def _render_service(blueprint: str, name: str) -> str:
    name_marker = f"    name: {name}\n"
    name_offset = blueprint.index(name_marker)
    start = blueprint.rfind("\n  - type:", 0, name_offset) + 1
    end = blueprint.find("\n  - type:", name_offset + len(name_marker))
    return blueprint[start:] if end == -1 else blueprint[start:end]


def _render_env_keys(service: str) -> set[str]:
    return set(re.findall(r"^      - key: ([A-Z0-9_]+)$", service, re.MULTILINE))


def test_api_traffic_health_checks_use_readiness():
    compose = Path("docker-compose.yml").read_text(encoding="utf-8")
    compose_api = compose.split("\n  api:\n", maxsplit=1)[1].split(
        "\n  worker:\n", maxsplit=1
    )[0]
    assert "http://localhost:8000/readyz" in compose_api
    assert "http://localhost:8000/healthz" not in compose_api

    blueprint = Path("render.yaml").read_text(encoding="utf-8")
    render_api = _render_service(blueprint, "itinera-api")
    assert "    healthCheckPath: /readyz\n" in render_api
    assert "    healthCheckPath: /healthz\n" not in render_api
    assert "    maxShutdownDelaySeconds: 300\n" in render_api
    assert "    autoDeployTrigger: off\n" in render_api


def test_render_environment_is_scoped_by_process_role():
    blueprint = Path("render.yaml").read_text(encoding="utf-8")
    assert "&shared_env" not in blueprint
    assert "*shared_env" not in blueprint

    api_keys = _render_env_keys(_render_service(blueprint, "itinera-api"))
    worker_service = _render_service(blueprint, "itinera-worker")
    outbox_service = _render_service(blueprint, "itinera-outbox")
    worker_keys = _render_env_keys(worker_service)
    outbox_keys = _render_env_keys(outbox_service)

    assert "    autoDeployTrigger: off\n" in worker_service
    assert "    autoDeployTrigger: off\n" in outbox_service

    api_service = _render_service(blueprint, "itinera-api")
    generation_switch = api_service.split(
        "      - key: GENERATION_ADMISSION_ENABLED\n", maxsplit=1
    )[1].split("      - key:", maxsplit=1)[0]
    assert "        sync: false\n" in generation_switch
    assert "        value:" not in generation_switch

    assert "DATABASE_URL" in api_keys & worker_keys & outbox_keys
    assert "REDIS_URL" in api_keys & worker_keys
    assert "REDIS_URL" not in outbox_keys
    assert {"CELERY_BROKER_URL", "CELERY_RESULT_BACKEND"}.isdisjoint(api_keys)
    assert {"CELERY_BROKER_URL", "CELERY_RESULT_BACKEND"} <= worker_keys
    assert {"CELERY_BROKER_URL", "CELERY_RESULT_BACKEND"} <= outbox_keys

    api_only = {
        "AUTH_JWT_SECRET",
        "APPLE_SIGN_IN_CLIENT_ID",
        "GENERATION_ADMISSION_ENABLED",
        "GENERATION_DISABLED_RETRY_AFTER_SECONDS",
        "ADMISSION_UNAVAILABLE_RETRY_AFTER_SECONDS",
        "READINESS_CHECK_TIMEOUT_SECONDS",
        "ITINERARY_STREAM_DATABASE_POOL_SIZE",
        "ITINERARY_STREAM_MAX_CONNECTIONS_PER_PRINCIPAL",
        "ITINERARY_STREAM_LEASE_TTL_SECONDS",
        "ITINERARY_STREAM_LEASE_RENEW_SECONDS",
    }
    assert api_only <= api_keys
    assert api_only.isdisjoint(worker_keys | outbox_keys)

    worker_only = {
        "ITINERARY_COMPOSER_PROVIDER",
        "OPENAI_API_KEY",
        "OLLAMA_API_KEY",
        "TRENDS_FEED_API_KEY",
        "APPLE_MAPS_PRIVATE_KEY",
    }
    assert worker_only <= worker_keys
    assert worker_only.isdisjoint(api_keys | outbox_keys)

    assert outbox_keys == {
        "ENV",
        "DATABASE_URL",
        "CELERY_BROKER_URL",
        "CELERY_RESULT_BACKEND",
        "OUTBOX_REDISPATCH_INITIAL_SECONDS",
        "OUTBOX_REDISPATCH_MAX_SECONDS",
    }


def test_stream_database_pool_budget_is_explicit_and_api_scoped():
    blueprint = Path("render.yaml").read_text(encoding="utf-8")
    api_service = _render_service(blueprint, "itinera-api")
    worker_service = _render_service(blueprint, "itinera-worker")
    outbox_service = _render_service(blueprint, "itinera-outbox")
    api_pool = api_service.split(
        "      - key: ITINERARY_STREAM_DATABASE_POOL_SIZE\n", maxsplit=1
    )[1].split("      - key:", maxsplit=1)[0]

    assert '        value: "10"\n' in api_pool
    assert "ITINERARY_STREAM_DATABASE_POOL_SIZE" not in worker_service
    assert "ITINERARY_STREAM_DATABASE_POOL_SIZE" not in outbox_service

    environment = Path(".env.example").read_text(encoding="utf-8")
    readme = Path("README.md").read_text(encoding="utf-8")
    sprint = Path("docs/sprints/atomic-admission-readiness.md").read_text(
        encoding="utf-8"
    )
    assert "ITINERARY_STREAM_DATABASE_POOL_SIZE=10" in environment
    for document in (environment, blueprint, readme, sprint):
        assert "10 + 20 + 10 = 40" in document
    assert "API instances × (30 + stream pool size)" in readme
    assert "API instances × (30 + stream pool size)" in sprint


def test_ci_has_a_separate_real_infrastructure_lane():
    workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
    unit_job, integration_job = workflow.split(
        "  backend-integration-test:\n", maxsplit=1
    )
    integration_job = integration_job.split("\n  ios-build-test:\n", maxsplit=1)[0]

    assert "run: python -m pytest\n" in unit_job
    assert "RUN_REAL_INFRA_TESTS" not in unit_job
    assert "image: postgres:16-alpine" in integration_job
    assert "image: redis:7-alpine" in integration_job
    assert 'RUN_REAL_INFRA_TESTS: "1"' in integration_job
    assert "run: python -m alembic upgrade head" in integration_job
    assert "run: python -m pytest -m integration" in integration_job
