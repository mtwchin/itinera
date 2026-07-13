from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

from backend.cache.redis import close_redis
from backend.config import get_settings
from backend.db.session import engine
from backend.observability.logging import configure_logging
from backend.observability.tracing import configure_tracing
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

    app.include_router(health.router)
    app.include_router(auth_router.router, prefix="/api/v1")
    app.include_router(itineraries.router, prefix="/api/v1")
    app.include_router(trips.router, prefix="/api/v1")

    Instrumentator().instrument(app).expose(app, endpoint="/metrics")

    return app


app = create_app()
