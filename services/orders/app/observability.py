"""OTel tracing, Prometheus metrics, and structured JSON logging for orders.

Tracing is best-effort: a malformed or unreachable OTLP endpoint must never
crash the app or block /healthz from serving (see setup_tracing).
"""

from __future__ import annotations

import json
import logging
import sys
import time
from collections.abc import Awaitable, Callable

from prometheus_client import CONTENT_TYPE_LATEST, Histogram, generate_latest
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "Duration of HTTP requests in seconds.",
    ["method", "route", "status"],
)


class JsonLogFormatter(logging.Formatter):
    """Emits one JSON object per line: timestamp, level, msg, trace_id."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "msg": record.getMessage(),
        }
        trace_id = getattr(record, "trace_id", None)
        if trace_id:
            payload["trace_id"] = trace_id
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging() -> logging.Logger:
    log = logging.getLogger("orders")
    log.setLevel(logging.INFO)
    log.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonLogFormatter())
    log.addHandler(handler)
    log.propagate = False
    return log


logger = configure_logging()


def current_trace_id() -> str | None:
    """Best-effort read of the active span's trace id, if OTel is set up."""
    try:
        from opentelemetry import trace

        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx is None or ctx.trace_id == 0:
            return None
        return format(ctx.trace_id, "032x")
    except Exception:
        return None


def setup_tracing(service_name: str, endpoint: str) -> None:
    """Configure the OTLP/HTTP tracer provider and W3C propagator.

    Never raises: any failure (bad endpoint, import issue, unreachable
    collector) is logged and swallowed so app startup and /healthz are
    unaffected.
    """
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )
        from opentelemetry.propagate import set_global_textmap
        from opentelemetry.sdk.resources import SERVICE_NAME, Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.trace.propagation.tracecontext import (
            TraceContextTextMapPropagator,
        )

        resource = Resource.create({SERVICE_NAME: service_name})
        provider = TracerProvider(resource=resource)
        exporter = OTLPSpanExporter(
            endpoint=f"{endpoint.rstrip('/')}/v1/traces", timeout=2
        )
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)
        set_global_textmap(TraceContextTextMapPropagator())
    except Exception:
        logger.warning("tracing setup failed; continuing without export")


def instrument_app(app) -> None:
    """Best-effort auto-instrumentation of FastAPI + outgoing httpx calls."""
    try:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        FastAPIInstrumentor.instrument_app(app)
    except Exception:
        logger.warning("FastAPI instrumentation failed; continuing without it")

    try:
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

        HTTPXClientInstrumentor().instrument()
    except Exception:
        logger.warning("httpx instrumentation failed; continuing without it")


def metrics_response() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


class ObservabilityMiddleware(BaseHTTPMiddleware):
    """Records the request-duration histogram and emits one JSON access-log
    line per request, including the active span's trace_id when present.
    """

    async def dispatch(
        self, request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            duration = time.perf_counter() - start
            self._record(request, 500, duration)
            raise

        duration = time.perf_counter() - start
        self._record(request, response.status_code, duration)
        return response

    def _record(self, request: Request, status_code: int, duration: float) -> None:
        route = self._route_template(request)
        http_request_duration_seconds.labels(
            method=request.method, route=route, status=str(status_code)
        ).observe(duration)

        trace_id = current_trace_id()
        extra = {"trace_id": trace_id} if trace_id else {}
        logger.info(
            "%s %s %s %.2fms",
            request.method,
            route,
            status_code,
            duration * 1000,
            extra=extra,
        )

    @staticmethod
    def _route_template(request: Request) -> str:
        route = request.scope.get("route")
        path = getattr(route, "path", None)
        return path if path else "unmatched"
