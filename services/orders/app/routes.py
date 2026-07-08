"""HTTP routes for the orders service."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from app.catalog_client import CatalogClient
from app.db import OrdersRepository
from app.observability import metrics_response

router = APIRouter()


class OrderCreate(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    product_id: str = Field(alias="productId")
    quantity: int


def get_repository(request: Request) -> OrdersRepository:
    return request.app.state.repository


def get_catalog_client(request: Request) -> CatalogClient:
    return request.app.state.catalog_client


@router.post("/orders", status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderCreate,
    repository: OrdersRepository = Depends(get_repository),
    catalog: CatalogClient = Depends(get_catalog_client),
) -> dict[str, Any]:
    if payload.quantity <= 0:
        raise HTTPException(status_code=400, detail="invalid quantity")

    product = await catalog.get_product(payload.product_id)
    if product is None:
        raise HTTPException(status_code=400, detail="invalid product")

    return await repository.create(payload.product_id, payload.quantity)


@router.get("/orders")
async def list_orders(
    repository: OrdersRepository = Depends(get_repository),
) -> list[dict[str, Any]]:
    return await repository.list()


@router.get("/orders/{order_id}")
async def get_order(
    order_id: str,
    repository: OrdersRepository = Depends(get_repository),
) -> dict[str, Any]:
    order = await repository.get(order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="not found")
    return order


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(
    repository: OrdersRepository = Depends(get_repository),
    catalog: CatalogClient = Depends(get_catalog_client),
) -> JSONResponse:
    db_ok = await repository.ping()
    catalog_ok = await catalog.ping()
    if db_ok and catalog_ok:
        return JSONResponse({"status": "ok"})
    return JSONResponse({"status": "unavailable"}, status_code=503)


@router.get("/metrics")
async def metrics():
    return metrics_response()
