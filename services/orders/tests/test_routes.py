"""Unit tests for the orders service HTTP contract.

These tests never touch a real Postgres instance: persistence is abstracted
behind ``OrdersRepository`` and an in-memory fake is injected via FastAPI's
``dependency_overrides``. The catalog HTTP call is stubbed with a fake
``CatalogClient`` so no network access occurs.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.db import InMemoryOrdersRepository
from app.main import app
from app.routes import get_catalog_client, get_repository

PRODUCTS = {
    "p1": {"id": "p1", "name": "Widget", "price": 9.99, "stock": 10},
}


class FakeCatalogClient:
    """Stand-in for CatalogClient; never performs real HTTP calls."""

    def __init__(self, products: dict[str, dict], reachable: bool = True) -> None:
        self._products = products
        self._reachable = reachable

    async def get_product(self, product_id: str):
        return self._products.get(product_id)

    async def ping(self) -> bool:
        return self._reachable


@pytest.fixture
def repository() -> InMemoryOrdersRepository:
    return InMemoryOrdersRepository()


@pytest.fixture
def catalog_client() -> FakeCatalogClient:
    return FakeCatalogClient(PRODUCTS)


@pytest.fixture(scope="module")
def test_client():
    # Entered once for the whole module: the lifespan attempts (and, in this
    # sandboxed test environment, fails fast on) a real Postgres connection,
    # so we pay that cost once rather than per test.
    with TestClient(app) as tc:
        yield tc


@pytest.fixture
def client(test_client, repository, catalog_client):
    app.dependency_overrides[get_repository] = lambda: repository
    app.dependency_overrides[get_catalog_client] = lambda: catalog_client
    yield test_client
    app.dependency_overrides.clear()


def test_post_order_valid_product_returns_201(client):
    response = client.post("/orders", json={"productId": "p1", "quantity": 2})

    assert response.status_code == 201
    body = response.json()
    assert body["productId"] == "p1"
    assert body["quantity"] == 2
    assert body["status"] == "created"
    assert "id" in body and body["id"]
    assert "createdAt" in body and body["createdAt"]


def test_post_order_unknown_product_returns_400(client):
    response = client.post("/orders", json={"productId": "nope", "quantity": 1})

    assert response.status_code == 400


def test_post_order_invalid_quantity_returns_400(client):
    response = client.post("/orders", json={"productId": "p1", "quantity": 0})

    assert response.status_code == 400


def test_get_orders_returns_created_order(client):
    create_response = client.post("/orders", json={"productId": "p1", "quantity": 1})
    order_id = create_response.json()["id"]

    list_response = client.get("/orders")

    assert list_response.status_code == 200
    ids = [order["id"] for order in list_response.json()]
    assert order_id in ids


def test_get_order_by_id_returns_created_order(client):
    create_response = client.post("/orders", json={"productId": "p1", "quantity": 3})
    order_id = create_response.json()["id"]

    get_response = client.get(f"/orders/{order_id}")

    assert get_response.status_code == 200
    assert get_response.json()["id"] == order_id


def test_get_order_by_unknown_id_returns_404(client):
    response = client.get("/orders/does-not-exist")

    assert response.status_code == 404


def test_healthz_returns_200(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_returns_200_when_dependencies_reachable(client):
    response = client.get("/readyz")

    assert response.status_code == 200


def test_readyz_returns_503_when_catalog_unreachable(test_client, repository):
    app.dependency_overrides[get_repository] = lambda: repository
    app.dependency_overrides[get_catalog_client] = lambda: FakeCatalogClient(
        PRODUCTS, reachable=False
    )

    response = test_client.get("/readyz")
    app.dependency_overrides.clear()

    assert response.status_code == 503


def test_metrics_endpoint_exposes_histogram(client):
    client.get("/healthz")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert "http_request_duration_seconds" in response.text


def test_default_port_is_8080():
    from app.config import Settings

    assert Settings().port == 8080


def test_port_env_is_honored(monkeypatch):
    from app.config import Settings

    monkeypatch.setenv("PORT", "9090")
    assert Settings().port == 9090


def test_orders_wrong_method_returns_405(client):
    response = client.put("/orders", json={"productId": "p1", "quantity": 1})

    assert response.status_code == 405


def test_healthz_wrong_method_returns_405(client):
    response = client.post("/healthz")

    assert response.status_code == 405
