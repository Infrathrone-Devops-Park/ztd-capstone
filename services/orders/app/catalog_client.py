"""HTTP client for validating products against the catalog service.

Uses httpx.AsyncClient; when opentelemetry-instrumentation-httpx is active
(see observability.instrument_app) outgoing requests automatically carry the
W3C traceparent header, propagating the active trace context downstream.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx


class CatalogClient:
    def __init__(self, base_url: str, timeout: float = 5.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(timeout=timeout)

    async def get_product(self, product_id: str) -> dict[str, Any] | None:
        """Return the product dict, or None if unknown/invalid/unreachable."""
        encoded_id = quote(product_id, safe="")
        try:
            response = await self._client.get(f"{self._base_url}/products/{encoded_id}")
        except httpx.HTTPError:
            return None
        if response.status_code != 200:
            return None
        try:
            return response.json()
        except ValueError:
            return None

    async def ping(self) -> bool:
        try:
            response = await self._client.get(f"{self._base_url}/products")
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    async def aclose(self) -> None:
        await self._client.aclose()
