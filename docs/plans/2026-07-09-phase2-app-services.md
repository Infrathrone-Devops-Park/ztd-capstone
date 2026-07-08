# Phase 2 — Application Microservices — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the four polyglot e-commerce microservices — `catalog` (Go), `api-gateway` (Node/TS Fastify), `orders` (Python FastAPI), `frontend` (React+Vite+Nginx) — each with health/readiness probes, Prometheus `/metrics`, OpenTelemetry OTLP tracing, structured JSON logs, unit tests, a production-grade multi-stage Dockerfile, and a top-level `docker-compose.yml` that runs the whole app + Postgres locally.

**Architecture:** Independent services communicating over HTTP. `frontend` → `api-gateway` → {`catalog`, `orders`}; `orders` → `catalog` (validate product) and → Postgres (persist). Every backend emits the three observability signals so later phases (Prometheus/Loki/Tempo) work with zero app changes. Local dev via docker-compose mirrors the k8s topology.

**Tech Stack:** Go 1.22 (net/http, prometheus/client_golang, otel-go), Node 20 / TypeScript / Fastify 4 (`@fastify/*`, `prom-client`, `@opentelemetry/*`), Python 3.12 / FastAPI / uvicorn (`prometheus-client`, `opentelemetry-*`, `psycopg[binary]`), React 18 + Vite + TypeScript, Postgres 16, Docker.

## Global Constraints

_Every task's requirements implicitly include this section._

- **⚠️ EXISTING-INFRA PROTECTION:** this phase touches NO AWS/k8s infra — pure app code + local docker. No terraform, no kubectl, no cluster access. Nothing here can affect existing infra.
- **Commits:** authored as `SaiPisey2 <piseysai0202@gmail.com>` (`git -c user.name=... -c user.email=...`). NO Claude attribution anywhere.
- **Ports (uniform across services):** app HTTP on `8080`; metrics on the same port at `/metrics`. Frontend Nginx on `8080`.
- **Health contract (every backend):** `GET /healthz` → `200 {"status":"ok"}` (liveness, no deps checked); `GET /readyz` → `200` when dependencies reachable else `503` (readiness).
- **Metrics contract:** `GET /metrics` → Prometheus text format including default process metrics + an HTTP request histogram named `http_request_duration_seconds` with labels `method`, `route`, `status`.
- **Tracing contract:** OTLP/HTTP exporter to endpoint from env `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`); service name from `OTEL_SERVICE_NAME`. Incoming/outgoing HTTP auto-instrumented; trace context propagated (W3C `traceparent`) on all downstream calls.
- **Logging contract:** structured JSON to stdout, one object per line, including `timestamp`, `level`, `msg`, and (when in a request) `trace_id`.
- **Config via env only** (12-factor). Each service ships a `.env.example`; real `.env` is gitignored. No secrets in code.
- **Containers:** multi-stage, final image runs as **non-root** user, minimal base (distroless or alpine), `EXPOSE 8080`, `HEALTHCHECK` hitting `/healthz` (or `/` for frontend).
- **Images build for `linux/amd64`** (cluster node arch).

---

## File Structure

```
services/
├── catalog/                     # Go
│   ├── go.mod, go.sum
│   ├── main.go                  # server bootstrap + routes + graceful shutdown
│   ├── handlers.go              # product handlers
│   ├── products.go              # in-memory product data + types
│   ├── observability.go         # otel + prometheus + json logger setup
│   ├── handlers_test.go
│   ├── Dockerfile               # multi-stage → distroless static, non-root
│   └── .env.example
├── api-gateway/                 # Node/TS Fastify
│   ├── package.json, tsconfig.json
│   ├── src/server.ts            # Fastify app factory + plugins
│   ├── src/routes.ts            # /api/products, /api/orders proxying
│   ├── src/observability.ts     # otel SDK init + metrics + logger
│   ├── src/config.ts            # env parsing
│   ├── test/routes.test.ts
│   ├── Dockerfile
│   └── .env.example
├── orders/                      # Python FastAPI
│   ├── pyproject.toml
│   ├── app/main.py              # FastAPI app + lifespan
│   ├── app/routes.py            # order endpoints
│   ├── app/db.py                # postgres pool + schema init
│   ├── app/catalog_client.py    # calls catalog to validate product
│   ├── app/observability.py     # otel + prometheus + logging
│   ├── app/config.py
│   ├── tests/test_routes.py
│   ├── Dockerfile
│   └── .env.example
├── frontend/                    # React + Vite
│   ├── package.json, tsconfig.json, vite.config.ts
│   ├── src/main.tsx, src/App.tsx, src/api.ts
│   ├── nginx.conf               # serve build, proxy /api → gateway, /healthz
│   ├── Dockerfile
│   └── .env.example
docker-compose.yml               # postgres + catalog + orders + api-gateway + frontend + otel-collector
```

**Note on task granularity:** each service is one task producing an independently testable, containerized deliverable. Because these are polyglot services, task steps specify exact **contracts, endpoints, env vars, ports, and behavioral test cases** and provide code for the tricky observability wiring; the implementer writes idiomatic full source to satisfy the contract + tests. This is deliberate — inlining thousands of lines of four-language source into the plan would be unmaintainable and error-prone. Implementers MUST match the contracts verbatim (routes, ports, JSON shapes, metric/env names) since later phases depend on them.

---

### Task 1: `catalog` service (Go)

**Files:** create everything under `services/catalog/` (see structure). **Test:** `handlers_test.go`.

**Interfaces:**
- Produces (HTTP API consumed by api-gateway and orders):
  - `GET /products` → `200 [{"id":string,"name":string,"price":number,"stock":int}]`
  - `GET /products/{id}` → `200 {product}` or `404 {"error":"not found"}`
  - `GET /healthz`, `GET /readyz` (always ready — no external deps), `GET /metrics`
- Seed data: at least 5 products with stable ids `p1`..`p5` (orders tests depend on `p1` existing).

- [ ] **Step 1: Write failing tests** (`handlers_test.go`) using `net/http/httptest`:
  - `GET /products` returns 200 and a JSON array of length ≥ 5.
  - `GET /products/p1` returns 200 with `id == "p1"`.
  - `GET /products/nope` returns 404.
  - `GET /healthz` returns 200 with body containing `"ok"`.
- [ ] **Step 2: Run tests, verify they fail** — `cd services/catalog && go test ./...` → FAIL (undefined handlers).
- [ ] **Step 3: Implement** — `products.go` (types + seed slice + lookup), `handlers.go` (the four handlers, JSON responses, request histogram middleware), `observability.go` (OTLP tracer provider from env, `promhttp` handler, slog JSON logger to stdout), `main.go` (mux wiring, otelhttp middleware, `:8080`, graceful shutdown on SIGTERM). Use `go.opentelemetry.io/otel` + `otelhttp`, `github.com/prometheus/client_golang`.
- [ ] **Step 4: Run tests, verify pass** — `go test ./...` → PASS; `go vet ./...` clean.
- [ ] **Step 5: Dockerfile** — stage 1 `golang:1.22` builds static binary (`CGO_ENABLED=0`); stage 2 `gcr.io/distroless/static:nonroot`, copy binary, `USER nonroot`, `EXPOSE 8080`, `HEALTHCHECK`. Build: `docker build -t ztd-catalog:test services/catalog` → succeeds. Run + curl: `docker run -d -p 8081:8080 ztd-catalog:test`, then `curl -s localhost:8081/products | jq 'length'` ≥ 5, `curl -s localhost:8081/metrics | grep http_request_duration_seconds`. Stop container.
- [ ] **Step 6: `.env.example`** — `OTEL_SERVICE_NAME=catalog`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`, `PORT=8080`.
- [ ] **Step 7: Commit** — `feat(catalog): Go product service with health, metrics, tracing`.

---

### Task 2: `api-gateway` service (Node/TS, Fastify)

**Files:** under `services/api-gateway/`. **Test:** `test/routes.test.ts` (vitest or node:test).

**Interfaces:**
- Consumes: catalog API (`CATALOG_URL`), orders API (`ORDERS_URL`).
- Produces (edge API consumed by frontend):
  - `GET /api/products` → proxies catalog `GET /products`.
  - `GET /api/products/:id` → proxies catalog `GET /products/{id}`.
  - `POST /api/orders` `{productId, quantity}` → proxies orders `POST /orders`.
  - `GET /api/orders` → proxies orders `GET /orders`.
  - `GET /healthz`, `GET /readyz` (checks catalog + orders reachable), `GET /metrics`.
- Propagates W3C trace context on downstream calls; starts the root span.

- [ ] **Step 1: Failing tests** — spin the Fastify app with `CATALOG_URL`/`ORDERS_URL` pointed at a mock (nock/undici mock or a stub server): assert `GET /api/products` returns the mocked catalog payload; `GET /healthz` → 200; `GET /readyz` → 503 when a dependency mock is down.
- [ ] **Step 2: Verify fail** — `cd services/api-gateway && npm test` → FAIL.
- [ ] **Step 3: Implement** — `config.ts` (env), `observability.ts` (OTel NodeSDK with `getNodeAutoInstrumentations` for http/fastify, `prom-client` registry + histogram, pino JSON logger with trace correlation), `routes.ts` (proxy handlers using `undici`/`fetch`, forwarding traceparent), `server.ts` (Fastify factory, register metrics route, health/ready). Entry `src/index.ts` starts OTel BEFORE importing the app.
- [ ] **Step 4: Verify pass** — `npm test` → PASS; `npm run build` (tsc) clean; `npm run lint` clean.
- [ ] **Step 5: Dockerfile** — stage 1 `node:20` `npm ci && npm run build`; stage 2 `node:20-slim` (or distroless/nodejs20), copy `dist` + prod deps, `USER node`, `EXPOSE 8080`, `HEALTHCHECK`. Build succeeds.
- [ ] **Step 6: `.env.example`** — `PORT=8080`, `CATALOG_URL=http://catalog:8080`, `ORDERS_URL=http://orders:8080`, `OTEL_SERVICE_NAME=api-gateway`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`.
- [ ] **Step 7: Commit** — `feat(api-gateway): Fastify edge service proxying catalog and orders`.

---

### Task 3: `orders` service (Python FastAPI)

**Files:** under `services/orders/`. **Test:** `tests/test_routes.py` (pytest + httpx/TestClient).

**Interfaces:**
- Consumes: Postgres (`DATABASE_URL`), catalog (`CATALOG_URL`) to validate `productId`.
- Produces:
  - `POST /orders` `{productId, quantity}` → validates product via catalog; `201 {id, productId, quantity, status:"created", createdAt}`; `400` if product missing/invalid.
  - `GET /orders` → `200 [orders]`; `GET /orders/{id}` → `200|404`.
  - `GET /healthz`; `GET /readyz` (checks DB + catalog); `GET /metrics`.
- Persists orders in a `orders` table auto-created on startup.

- [ ] **Step 1: Failing tests** — use FastAPI `TestClient`; mock catalog with `respx`/monkeypatch and use a test Postgres (or `DATABASE_URL` to a disposable container; if unavailable, abstract the repo behind an interface and inject an in-memory fake for tests). Assert: `POST /orders` with valid `p1` → 201; with unknown product → 400; `GET /orders` returns created order; `GET /healthz` → 200.
- [ ] **Step 2: Verify fail** — `cd services/orders && pytest` → FAIL.
- [ ] **Step 3: Implement** — `config.py` (env via pydantic-settings), `observability.py` (OTel with FastAPI + httpx + psycopg instrumentation, `prometheus-client` ASGI middleware + histogram, JSON logging via `logging` config with trace ids), `db.py` (psycopg connection pool, `init_schema()` creating `orders`), `catalog_client.py` (httpx GET with propagated context), `routes.py` (APIRouter), `main.py` (app factory, lifespan runs `init_schema`, instrument app).
- [ ] **Step 4: Verify pass** — `pytest` → PASS; `ruff check` clean.
- [ ] **Step 5: Dockerfile** — stage 1 builds wheels; stage 2 `python:3.12-slim` (or distroless/python3), non-root `USER app`, `EXPOSE 8080`, run `uvicorn app.main:app --host 0.0.0.0 --port 8080`, `HEALTHCHECK`. Build succeeds.
- [ ] **Step 6: `.env.example`** — `PORT=8080`, `DATABASE_URL=postgresql://ztd:ztd@postgres:5432/ztd`, `CATALOG_URL=http://catalog:8080`, `OTEL_SERVICE_NAME=orders`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`.
- [ ] **Step 7: Commit** — `feat(orders): FastAPI order service with Postgres, catalog validation, observability`.

---

### Task 4: `frontend` service (React + Vite + Nginx)

**Files:** under `services/frontend/`.

**Interfaces:**
- Consumes: api-gateway via relative `/api/*` (Nginx proxies to `API_GATEWAY_URL`).
- Produces: static SPA; Nginx serves on `8080`, proxies `/api/` → gateway, and answers `GET /healthz` → 200 (for k8s probes). Generates real user traffic for dashboards.

- [ ] **Step 1: Minimal test** — a component/unit test (vitest + testing-library) asserting the product list renders items from a mocked `fetch('/api/products')`.
- [ ] **Step 2: Verify fail** — `cd services/frontend && npm test` → FAIL.
- [ ] **Step 3: Implement** — Vite React TS app: `api.ts` (fetch products, create order), `App.tsx` (product grid + "order" button + orders list), basic styling. Keep minimal but functional.
- [ ] **Step 4: Verify pass** — `npm test` → PASS; `npm run build` produces `dist/`.
- [ ] **Step 5: `nginx.conf` + Dockerfile** — nginx.conf: listen 8080, `root /usr/share/nginx/html`, `location /healthz { return 200 'ok'; }`, `location /api/ { proxy_pass ${API_GATEWAY_URL}; proxy_set_header ... }` (use envsubst at start for `API_GATEWAY_URL`). Dockerfile: stage 1 `node:20` build; stage 2 `nginxinc/nginx-unprivileged:alpine` (non-root), copy `dist` + template, `EXPOSE 8080`. Build succeeds; `docker run` + `curl localhost:PORT/healthz` → `ok`.
- [ ] **Step 6: `.env.example`** — `API_GATEWAY_URL=http://api-gateway:8080`.
- [ ] **Step 7: Commit** — `feat(frontend): React storefront served by unprivileged Nginx`.

---

### Task 5: `docker-compose.yml` — full local stack + end-to-end smoke

**Files:** create `docker-compose.yml` (repo root); create `otel-collector-config.yaml` (repo root, minimal collector logging traces to stdout for local dev).

**Interfaces:**
- Consumes: all four service Dockerfiles + Postgres + otel-collector image.
- Produces: `docker compose up` brings up the whole app locally on mapped ports; a documented smoke flow.

- [ ] **Step 1: Write `docker-compose.yml`** — services: `postgres` (postgres:16, healthcheck, volume, env ztd/ztd/ztd), `otel-collector` (otel/opentelemetry-collector-contrib, config mounted, receives OTLP 4318), `catalog`, `orders` (depends_on postgres+catalog healthy), `api-gateway` (depends_on catalog+orders), `frontend` (depends_on api-gateway). Wire env from the `.env.example` values. Map frontend to `localhost:8080`.
- [ ] **Step 2: Bring stack up** — `docker compose up -d --build`; `docker compose ps` shows all healthy.
- [ ] **Step 3: End-to-end smoke** (the phase's integration test):
  - `curl -s localhost:8080/healthz` → `ok`.
  - `curl -s localhost:8080/api/products | jq 'length'` ≥ 5.
  - `curl -s -XPOST localhost:8080/api/orders -H 'content-type: application/json' -d '{"productId":"p1","quantity":2}'` → 201 with an order id.
  - `curl -s localhost:8080/api/orders | jq 'length'` ≥ 1.
  - `docker compose logs otel-collector | grep -i 'span'` shows traces arriving (gateway→catalog/orders chain).
  - Each backend `/metrics` reachable and shows `http_request_duration_seconds`.
- [ ] **Step 4: Tear down** — `docker compose down -v`.
- [ ] **Step 5: Commit** — `feat: docker-compose full local stack with otel collector and smoke flow`.

---

## Self-Review

- **Spec coverage:** Implements spec §3 (four polyglot services + Postgres + per-service observability endpoints + health/readiness). Contracts (routes/ports/JSON) are fixed here so spec §6 (observability wiring) and Phase 3 (Helm) can rely on them. Frontend generates traffic per spec §3.
- **Placeholder scan:** none — every task defines concrete endpoints, env vars, ports, test cases, and container requirements. Full source is delegated to implementers by explicit contract (documented rationale), not left vague.
- **Interface consistency:** ports uniformly `8080`; product id `p1` used by both catalog seed (Task 1) and orders test (Task 3); `CATALOG_URL`/`ORDERS_URL`/`API_GATEWAY_URL`/`DATABASE_URL`/`OTEL_*` env names consistent across tasks and compose.

## Phase Exit Criteria

- Four services build as non-root multi-stage images; unit tests pass per service.
- `docker compose up --build` runs the full app; the E2E smoke flow (browse → order → traces in collector → metrics exposed) passes.
- No AWS/cluster interaction occurred. All commits authored SaiPisey2, no Claude attribution, pushed to `main`.
- Contracts locked for Phase 3 (Helm chart) and Phase 5 (observability).
