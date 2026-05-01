from functools import lru_cache
from typing import Literal

from pydantic import Field
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
    cors_origins: list[str] = ["http://localhost:5173", "http://localhost:3000"]

    database_url: str = Field(
        default="postgresql+asyncpg://itinera:itinera@localhost:5432/itinera"
    )
    redis_url: str = Field(default="redis://localhost:6379/0")
    celery_broker_url: str = Field(default="redis://localhost:6379/1")
    celery_result_backend: str = Field(default="redis://localhost:6379/2")

    anthropic_api_key: str | None = None
    anthropic_model: str = "claude-sonnet-4-6"

    google_maps_api_key: str | None = None
    tiktok_api_key: str | None = None
    tiktok_ms_token: str | None = None
    youtube_api_key: str | None = None

    clerk_jwks_url: str | None = None
    clerk_issuer: str | None = None

    otel_exporter_otlp_endpoint: str = "http://localhost:4318"
    otel_service_name: str = "itinera-api"

    cache_trending_ttl_seconds: int = 6 * 60 * 60
    cache_geocode_ttl_seconds: int = 30 * 24 * 60 * 60
    cache_llm_ttl_seconds: int = 24 * 60 * 60


@lru_cache
def get_settings() -> Settings:
    return Settings()
