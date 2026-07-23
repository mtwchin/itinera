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
    assert "python -m backend.workers.preflight && exec celery" in worker_service
    assert "backend.workers.preflight" not in outbox_service

    api_service = _render_service(blueprint, "itinera-api")
    body_limit = api_service.split(
        "      - key: API_REQUEST_MAX_BODY_BYTES\n", maxsplit=1
    )[1].split("      - key:", maxsplit=1)[0]
    assert '        value: "262144"\n' in body_limit
    assert "API_REQUEST_MAX_BODY_BYTES" not in worker_service
    assert "API_REQUEST_MAX_BODY_BYTES" not in outbox_service
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

    edit_provider_keys = {
        "ITINERARY_COMPOSER_PROVIDER",
        "OPENAI_API_KEY",
        "OPENAI_MODEL",
        "OPENAI_REQUEST_TIMEOUT_SECONDS",
    }
    assert edit_provider_keys <= api_keys & worker_keys
    assert edit_provider_keys.isdisjoint(outbox_keys)

    api_only = {
        "AUTH_JWT_SECRET",
        "APPLE_SIGN_IN_CLIENT_ID",
        "GENERATION_ADMISSION_ENABLED",
        "GENERATION_DISABLED_RETRY_AFTER_SECONDS",
        "ADMISSION_UNAVAILABLE_RETRY_AFTER_SECONDS",
        "READINESS_CHECK_TIMEOUT_SECONDS",
        "API_REQUEST_MAX_BODY_BYTES",
        "ITINERARY_STREAM_DATABASE_POOL_SIZE",
        "ITINERARY_STREAM_MAX_CONNECTIONS_PER_PRINCIPAL",
        "ITINERARY_STREAM_LEASE_TTL_SECONDS",
        "ITINERARY_STREAM_LEASE_RENEW_SECONDS",
        "ITINERARY_EDITOR_MAX_OUTPUT_TOKENS",
    }
    assert api_only <= api_keys
    assert api_only.isdisjoint(worker_keys | outbox_keys)

    worker_only = {
        "CELERY_BROKER_VISIBILITY_TIMEOUT_SECONDS",
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
    assert (
        "image: postgres:16-alpine@sha256:"
        "57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"
    ) in integration_job
    assert (
        "image: redis:7-alpine@sha256:"
        "6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99"
    ) in integration_job
    assert 'RUN_REAL_INFRA_TESTS: "1"' in integration_job
    assert "run: python -m alembic upgrade head" in integration_job
    assert "run: python -m pytest -m integration" in integration_job


def test_ios_ci_verifies_the_pinned_xcodegen_archive_before_extracting_it():
    workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
    ios_job = workflow.split("  ios-build-test:\n", maxsplit=1)[1]
    install_step = ios_job.split("      - name: Regenerate project", maxsplit=1)[0]

    assert "XCODEGEN_VERSION: 2.45.4" in ios_job
    assert (
        "XCODEGEN_SHA256: "
        "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
    ) in ios_job
    assert "shasum -a 256 \"$archive\"" in install_step
    assert "XcodeGen archive checksum mismatch." in install_step
    assert install_step.index("actual_sha256=") < install_step.index("ditto -x -k")


def test_ios_scheme_includes_a_network_independent_ui_test_target():
    project = Path("ios/project.yml").read_text(encoding="utf-8")
    workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")

    assert "  ItineraUITests:\n    type: bundle.ui-testing" in project
    assert "    sources: [ItineraUITests]" in project
    assert "        - name: ItineraUITests" in project
    assert "-only-testing:" not in workflow.split("  ios-build-test:\n", maxsplit=1)[1]


def test_ci_actions_are_pinned_to_immutable_commit_ids():
    workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")

    expected = {
        "actions/checkout": "34e114876b0b11c390a56381ad16ebd13914f8d5",
        "actions/setup-node": "49933ea5288caeca8642d1e84afbd3f7d6820020",
        "actions/setup-python": "a26af69be951a213d495a4c3e4e4022e16d87065",
        "actions/upload-artifact": "ea165f8d65b6e75b540449e92b4886f43607fa02",
        "aquasecurity/trivy-action": "a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8",
        "anchore/sbom-action": "e22c389904149dbc22b58101806040fa8d37a610",
    }
    for action, revision in expected.items():
        assert f"uses: {action}@{revision}" in workflow

    assert "uses: actions/checkout@v" not in workflow
    assert "uses: actions/setup-node@v" not in workflow
    assert "uses: actions/setup-python@v" not in workflow
    assert "uses: actions/upload-artifact@v" not in workflow
    assert "uses: aquasecurity/trivy-action@v" not in workflow
    assert "uses: anchore/sbom-action@v" not in workflow


def test_hosted_provider_sdks_are_exactly_pinned():
    requirements = Path("requirements.txt").read_text(encoding="utf-8")

    assert "anthropic==0.116.0" in requirements
    assert "google-genai==2.11.0" in requirements
    assert "anthropic>=" not in requirements
    assert "google-genai>=" not in requirements


def test_prometheus_metrics_are_opt_in_and_not_enabled_in_public_production_config():
    settings = Path("backend/config.py").read_text(encoding="utf-8")
    main = Path("backend/main.py").read_text(encoding="utf-8")
    environment = Path(".env.example").read_text(encoding="utf-8")
    blueprint = Path("render.yaml").read_text(encoding="utf-8")

    assert "metrics_enabled: bool = False" in settings
    assert "if settings.metrics_enabled:" in main
    assert "METRICS_ENABLED=true" in environment
    assert "METRICS_ENABLED" not in _render_service(blueprint, "itinera-api")


def test_container_base_image_is_pinned_to_an_immutable_digest():
    dockerfile = Path("Dockerfile").read_text(encoding="utf-8")
    image = (
        "python:3.12-slim@sha256:"
        "57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de"
    )

    assert dockerfile.count(f"FROM {image}") == 2
    assert "FROM python:3.12-slim AS" not in dockerfile


def test_declared_external_service_images_are_pinned_to_digests():
    compose = Path("docker-compose.yml").read_text(encoding="utf-8")

    for image in (
        "postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777",
        "redis:7-alpine@sha256:6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99",
        "jaegertracing/all-in-one:latest@sha256:ab6f1a1f0fb49ea08bcd19f6b84f6081d0d44b364b6de148e1798eb5816bacac",
    ):
        assert f"image: {image}" in compose


def test_ci_blocks_on_pinned_dependency_secret_and_container_scans():
    workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
    scan_job = workflow.split("  supply-chain-scan:\n", maxsplit=1)[1].split(
        "\n  ios-build-test:\n", maxsplit=1
    )[0]
    trivy = "aquasecurity/trivy-action@a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8"

    assert scan_job.count(trivy) == 2
    assert "scan-type: fs" in scan_job
    assert "scanners: vuln,secret" in scan_job
    assert "image-ref: itinera:ci" in scan_job
    assert 'exit-code: "1"' in scan_job
    assert "docker build --pull=false --tag itinera:ci ." in scan_job
    assert "anchore/sbom-action@e22c389904149dbc22b58101806040fa8d37a610" in scan_job
    assert "format: cyclonedx-json" in scan_job
    assert "artifact-name: itinera-runtime-sbom" in scan_job
    assert "upload-artifact-retention: 90" in scan_job
