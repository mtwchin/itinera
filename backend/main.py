from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from backend.auth import validate_auth_settings
from backend.config import get_settings
from backend.observability.logging import configure_logging
from backend.observability.tracing import configure_tracing
from backend.routers import auth as auth_router
from backend.routers import health, itineraries


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    validate_auth_settings(settings)
    app = FastAPI(
        title="Itinera API",
        version="1.0.0",
        lifespan=lifespan,
    )

    # Middleware (incl. OTel instrumentation) must be added before startup.
    configure_logging(settings.log_level)
    configure_tracing(app, settings)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(health.router)
    app.include_router(auth_router.router, prefix="/api/v1")
    app.include_router(itineraries.router, prefix="/api/v1")

    Instrumentator().instrument(app).expose(app, endpoint="/metrics")

    return app


app = create_app()
