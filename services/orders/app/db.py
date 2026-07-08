"""Order persistence abstracted behind a small repository interface.

``PostgresOrdersRepository`` is the production implementation backed by a
psycopg connection pool. ``InMemoryOrdersRepository`` is a fake used by unit
tests so they never require a live Postgres instance.
"""

from __future__ import annotations

import uuid
from abc import ABC, abstractmethod
from datetime import UTC, datetime
from typing import Any

import psycopg
from psycopg_pool import ConnectionPool
from starlette.concurrency import run_in_threadpool


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


class OrdersRepository(ABC):
    """Persistence contract for orders. Implementations must be async-safe."""

    @abstractmethod
    async def create(self, product_id: str, quantity: int) -> dict[str, Any]: ...

    @abstractmethod
    async def list(self) -> list[dict[str, Any]]: ...

    @abstractmethod
    async def get(self, order_id: str) -> dict[str, Any] | None: ...

    @abstractmethod
    async def ping(self) -> bool: ...


class InMemoryOrdersRepository(OrdersRepository):
    """In-memory fake used for unit tests; has no external dependencies."""

    def __init__(self) -> None:
        self._orders: dict[str, dict[str, Any]] = {}

    async def create(self, product_id: str, quantity: int) -> dict[str, Any]:
        order = {
            "id": str(uuid.uuid4()),
            "productId": product_id,
            "quantity": quantity,
            "status": "created",
            "createdAt": _now_iso(),
        }
        self._orders[order["id"]] = order
        return order

    async def list(self) -> list[dict[str, Any]]:
        return list(self._orders.values())

    async def get(self, order_id: str) -> dict[str, Any] | None:
        return self._orders.get(order_id)

    async def ping(self) -> bool:
        return True


def _row_to_order(row: tuple) -> dict[str, Any]:
    order_id, product_id, quantity, status, created_at = row
    return {
        "id": str(order_id),
        "productId": product_id,
        "quantity": quantity,
        "status": status,
        "createdAt": created_at.isoformat(),
    }


class PostgresOrdersRepository(OrdersRepository):
    """Postgres-backed repository using a psycopg (v3) connection pool."""

    def __init__(self, database_url: str, open_timeout: float = 1.0) -> None:
        self._database_url = database_url
        self._open_timeout = open_timeout
        self._pool = ConnectionPool(database_url, min_size=1, max_size=5, open=False)

    def open(self) -> None:
        self._pool.open(wait=True, timeout=self._open_timeout)

    def close(self) -> None:
        self._pool.close()

    def init_schema(self) -> None:
        with self._pool.connection() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS orders (
                    id UUID PRIMARY KEY,
                    product_id TEXT NOT NULL,
                    quantity INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL
                )
                """
            )

    async def create(self, product_id: str, quantity: int) -> dict[str, Any]:
        order_id = uuid.uuid4()
        created_at = datetime.now(UTC)

        def _insert() -> None:
            with self._pool.connection() as conn:
                conn.execute(
                    "INSERT INTO orders (id, product_id, quantity, status, created_at) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (order_id, product_id, quantity, "created", created_at),
                )

        await run_in_threadpool(_insert)
        return {
            "id": str(order_id),
            "productId": product_id,
            "quantity": quantity,
            "status": "created",
            "createdAt": created_at.isoformat(),
        }

    async def list(self) -> list[dict[str, Any]]:
        def _select() -> list[dict[str, Any]]:
            with self._pool.connection() as conn:
                rows = conn.execute(
                    "SELECT id, product_id, quantity, status, created_at FROM orders "
                    "ORDER BY created_at"
                ).fetchall()
            return [_row_to_order(row) for row in rows]

        return await run_in_threadpool(_select)

    async def get(self, order_id: str) -> dict[str, Any] | None:
        def _select_one() -> dict[str, Any] | None:
            try:
                with self._pool.connection() as conn:
                    row = conn.execute(
                        "SELECT id, product_id, quantity, status, created_at "
                        "FROM orders WHERE id = %s",
                        (order_id,),
                    ).fetchone()
            except (psycopg.Error, ValueError):
                return None
            return _row_to_order(row) if row else None

        return await run_in_threadpool(_select_one)

    async def ping(self) -> bool:
        def _ping() -> bool:
            with self._pool.connection() as conn:
                conn.execute("SELECT 1")
            return True

        try:
            return await run_in_threadpool(_ping)
        except psycopg.Error:
            return False
