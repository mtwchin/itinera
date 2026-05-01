from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from backend.config import get_settings
from backend.observability.logging import configure_logging
from backend.observability.tracing import configure_tracing
from backend.routers import geocode, health, itineraries


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    configure_logging(settings.log_level)
    configure_tracing(app, settings)
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="Itinera API",
        version="2.0.0",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(health.router)
    app.include_router(itineraries.router, prefix="/api")
    app.include_router(geocode.router, prefix="/api")

    Instrumentator().instrument(app).expose(app, endpoint="/metrics")

    return app


app = create_app()
