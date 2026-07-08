"""FastAPI app factory + lifespan for the orders service."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.catalog_client import CatalogClient
from app.config import settings
from app.db import PostgresOrdersRepository
from app.observability import (
    ObservabilityMiddleware,
    instrument_app,
    logger,
    setup_tracing,
)
from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    repository = PostgresOrdersRepository(settings.database_url)
    catalog_client = CatalogClient(settings.catalog_url)

    try:
        repository.open()
        repository.init_schema()
    except Exception:
        logger.warning("database unavailable at startup; /readyz will report 503")

    app.state.repository = repository
    app.state.catalog_client = catalog_client
    try:
        yield
    finally:
        try:
            repository.close()
        except Exception:
            pass
        await catalog_client.aclose()


def create_app() -> FastAPI:
    setup_tracing(settings.otel_service_name, settings.otel_exporter_otlp_endpoint)

    application = FastAPI(title="orders", lifespan=lifespan)
    application.add_middleware(ObservabilityMiddleware)
    application.include_router(router)
    instrument_app(application)
    return application


app = create_app()
