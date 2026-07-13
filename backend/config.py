from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    env: Literal["dev", "test", "prod"] = "dev"
    log_level: str = "INFO"

    api_host: str = "0.0.0.0"
    api_port: int = 8000

    database_url: str = Field(
        default="postgresql+asyncpg://itinera:itinera@localhost:5432/itinera"
    )

    @field_validator("database_url")
    @classmethod
    def _force_asyncpg_driver(cls, value: str) -> str:
        # Managed hosts (Render, Railway, Heroku) hand out postgres:// URLs;
        # SQLAlchemy needs the asyncpg dialect spelled out.
        if value.startswith("postgres://"):
            return value.replace("postgres://", "postgresql+asyncpg://", 1)
        if value.startswith("postgresql://"):
            return value.replace("postgresql://", "postgresql+asyncpg://", 1)
        return value
    redis_url: str = Field(default="redis://localhost:6379/0")
    redis_operation_timeout_seconds: float = Field(default=0.5, gt=0, le=5)
    readiness_check_timeout_seconds: float = Field(default=2.0, gt=0, le=10)
    readiness_cache_ttl_seconds: float = Field(default=2.0, gt=0, le=30)
    itinerary_stream_reconcile_seconds: float = Field(default=2.0, gt=0, le=30)
    itinerary_stream_max_seconds: int = Field(default=5 * 60, ge=30, le=60 * 60)
    itinerary_stream_database_timeout_seconds: float = Field(
        default=3.0, gt=0, le=30
    )
    itinerary_stream_database_pool_size: int = Field(default=10, ge=1, le=100)
    itinerary_stream_max_connections_per_principal: int = Field(
        default=2, ge=1, le=20
    )
    itinerary_stream_lease_ttl_seconds: int = Field(default=30, ge=5, le=5 * 60)
    itinerary_stream_lease_renew_seconds: int = Field(default=10, ge=1, le=2 * 60)
    celery_broker_url: str = Field(default="redis://localhost:6379/1")
    celery_result_backend: str = Field(default="redis://localhost:6379/2")

    itinerary_composer_provider: Literal["ollama", "anthropic", "openai"] = "ollama"
    ollama_base_url: str = "http://localhost:11434/api"
    ollama_model: str = "qwen2.5:7b-instruct"
    ollama_api_key: str | None = None
    ollama_request_timeout_seconds: int = Field(default=180, ge=1, le=600)
    anthropic_api_key: str | None = None
    anthropic_model: str = "claude-opus-4-8"
    openai_api_key: str | None = None
    openai_model: str = "gpt-5.6-luna"
    openai_request_timeout_seconds: int = Field(default=180, ge=1, le=600)

    generation_admission_enabled: bool = True
    generation_disabled_retry_after_seconds: int = Field(default=60, ge=1, le=3600)
    admission_unavailable_retry_after_seconds: int = Field(default=5, ge=1, le=300)
    rate_limit_generations_per_window: int = Field(
        default=10, ge=1, le=1_000_000_000
    )
    rate_limit_window_seconds: int = Field(default=60 * 60, ge=1, le=7 * 24 * 60 * 60)
    rate_limit_global_generations_per_window: int = Field(
        default=1_000, ge=1, le=1_000_000_000
    )
    rate_limit_guest_sessions_per_window: int = Field(
        default=20, ge=1, le=1_000_000_000
    )
    rate_limit_global_guest_sessions_per_window: int = Field(
        default=5_000, ge=1, le=1_000_000_000
    )

    # Guest sessions use short-lived signed access tokens and opaque, rotating
    # refresh tokens. Production must override the development signing secret.
    auth_jwt_secret: str = "dev-only-change-this-signing-secret"
    auth_jwt_issuer: str = "itinera-api"
    auth_jwt_audience: str = "itinera-ios"
    auth_access_token_ttl_seconds: int = 15 * 60
    auth_refresh_token_ttl_seconds: int = 30 * 24 * 60 * 60
    auth_refresh_retry_grace_seconds: int = 30
    apple_sign_in_client_id: str | None = None

    # A worker owns a running job until this lease expires. Progress callbacks
    # renew the lease so a broker redelivery cannot execute the same job twice.
    itinerary_job_lease_seconds: int = 60 * 60
    outbox_redispatch_initial_seconds: int = 5 * 60
    outbox_redispatch_max_seconds: int = 60 * 60

    google_maps_api_key: str | None = None
    tiktok_api_key: str | None = None
    tiktok_ms_token: str | None = None
    youtube_api_key: str | None = None

    # Provider selection is explicit so a production deployment cannot
    # silently present development fixtures as live trend data or mix Google
    # geocoding content with an Apple map. The HTTP trends feed is an internal,
    # normalized contract backed by a commercially licensed source.
    trends_provider: Literal["synthetic", "tiktok_research", "http"] = "synthetic"
    trends_feed_url: str | None = None
    trends_feed_api_key: str | None = None
    maps_provider: Literal["synthetic", "google", "apple"] = "synthetic"
    apple_maps_team_id: str | None = None
    apple_maps_key_id: str | None = None
    apple_maps_private_key: str | None = None

    clerk_jwks_url: str | None = None
    clerk_issuer: str | None = None

    otel_exporter_otlp_endpoint: str = "http://localhost:4318"
    otel_service_name: str = "itinera-api"

    cache_trending_ttl_seconds: int = 6 * 60 * 60
    cache_llm_ttl_seconds: int = 24 * 60 * 60

    @model_validator(mode="after")
    def _validate_stream_lease_timing(self) -> "Settings":
        operation_budget = max(
            self.redis_operation_timeout_seconds,
            self.itinerary_stream_database_timeout_seconds,
        )
        if (
            self.itinerary_stream_lease_renew_seconds + operation_budget
            >= self.itinerary_stream_lease_ttl_seconds
        ):
            raise ValueError(
                "ITINERARY_STREAM_LEASE_TTL_SECONDS must exceed the renewal "
                "interval plus the longest bounded stream operation"
            )
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
