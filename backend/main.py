from contextlib import asynccontextmanager
from uuid import uuid4

from fastapi import FastAPI, Request
from loguru import logger
from opentelemetry import trace
from prometheus_fastapi_instrumentator import Instrumentator

from backend.cache.redis import close_redis
from backend.config import get_settings
from backend.db.session import engine
from backend.observability.logging import configure_logging
from backend.observability.tracing import configure_tracing
from backend.request_body_limit import RequestBodyLimitMiddleware
from backend.routers import auth as auth_router
from backend.routers import health, itineraries, trips
from backend.stream_status import terminate_stream_status_pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    del app
    try:
        yield
    finally:
        health.reset_readiness_cache()
        terminate_stream_status_pool()
        await close_redis()
        await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="Itinera API",
        version="1.0.0",
        lifespan=lifespan,
    )

    # Middleware (incl. OTel instrumentation) must be added before startup.
    configure_logging(settings.log_level)
    configure_tracing(app, settings)
    app.add_middleware(
        RequestBodyLimitMiddleware,
        max_body_bytes=settings.api_request_max_body_bytes,
    )

    @app.middleware("http")
    async def add_request_correlation_id(request: Request, call_next):
        """Expose a server-generated support ID without trusting client input."""

        request_id = uuid4().hex
        request.state.request_id = request_id
        span = trace.get_current_span()
        if span.is_recording():
            span.set_attribute("itinera.request_id", request_id)
        with logger.contextualize(request_id=request_id):
            response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        response.headers.setdefault("Cache-Control", "no-store")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    app.include_router(health.router)
    app.include_router(auth_router.router, prefix="/api/v1")
    app.include_router(itineraries.router, prefix="/api/v1")
    app.include_router(trips.router, prefix="/api/v1")

    if settings.metrics_enabled:
        Instrumentator().instrument(app).expose(app, endpoint="/metrics")

    return app


app = create_app()
