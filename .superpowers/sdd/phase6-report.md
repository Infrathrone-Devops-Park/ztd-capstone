# Phase 6 — App Deploy to EKS + In-Cluster E2E — Report

**Status:** DONE
**Date:** 2026-07-09
**Image tag (pinned):** `sha-38e32ab` (all 4 images)
**Cluster:** ztd-demo / ap-south-1 / account 514422154867 / profile infrathrone-new

---

## Task 1 — Build + push images to ECR (linux/amd64)

`scripts/build-push-images.sh` builds all four services with
`docker buildx build --platform linux/amd64 --push` (host is arm64 → cross-build).

All four images pushed to `514422154867.dkr.ecr.ap-south-1.amazonaws.com/ztd-capstone/*:sha-38e32ab`
and confirmed **linux/amd64** via `docker buildx imagetools inspect`:

| repo | image digest (manifest) | Platform |
|------|--------------------------|----------|
| frontend    | sha256:8527ed2b… | linux/amd64 |
| api-gateway | sha256:137269ca… | linux/amd64 |
| orders      | sha256:1bfbcde9… | linux/amd64 |
| catalog     | sha256:8d3be7cf… | linux/amd64 |

(Each tag is an OCI index with the amd64 manifest + a build-attestation manifest — the
`unknown/unknown` entry is the SBOM/provenance attestation, not a second arch.)

---

## Task 2 — Terraform app deploy (secret + helm_release)

**Files:** `terraform/stack/app.tf` (new), `terraform/stack/variables.tf` (+`app_image_tag`, `app_deploy_enabled`).

- `random_password.postgres` (len 20, no special) → `kubernetes_secret.postgres`
  `ztd-capstone-postgres` in `dev` (keys `postgres-password`, `database-url` =
  `postgresql://ztd:<pw>@postgres:5432/ztd`). Never committed.
- `helm_release.app` deploys the Phase 3 chart into `dev`, `image.tag=var.app_image_tag`,
  `depends_on` the secret + kube-prometheus-stack (ServiceMonitor CRD).

**Plan (final, authoritative apply):** `0 to add, 1 to change, 0 to destroy` — only
`helm_release.app` in-place; **0 destroy of pre-existing infra**. Subsequent
`terraform plan` → **No changes** (idempotent).

**Rollout (platform-only placement — SAFETY):**

```
ztd-capstone-api-gateway   1/1  ip-192-168-174-121 (platform)
ztd-capstone-catalog       1/1  ip-192-168-125-246 (platform)
ztd-capstone-frontend      1/1  ip-192-168-125-246 (platform)
ztd-capstone-orders        1/1  ip-192-168-125-246 (platform)
ztd-capstone-postgres-0    1/1  ip-192-168-174-121 (platform)
```

**Zero** app pods on ng-dense (ip-192-168-6-232, ip-192-168-91-64). Postgres PVC bound via
EBS CSI (gp2). All 4 Services, 4 ServiceMonitors, 11 NetworkPolicies, 1 Ingress present in dev.

### Chart fixes made during deploy (committed)

1. **Inter-service URLs used the container port (`:8080`) but the chart Service listens on
   port 80** → `http://catalog:8080` hit an unmapped ClusterIP port and hung, breaking
   orders/api-gateway `/readyz`. Fixed all inter-service env URLs to the Service port
   (`http://catalog`, `http://orders`, `http://api-gateway`).
2. **OTLP endpoint** corrected to the real Phase 5 collector Service:
   `http://opentelemetry-collector.observability:4318`.
3. **catalog `allowFrom`** now includes `orders` (orders validates products against catalog
   directly), plus observability scrape/OTLP egress allowances (defense-in-depth; note the
   VPC-CNI network-policy engine is **off** on this cluster — `--enable-network-policy=false`
   — so policies are correctness/documentation, not enforced).
4. **`wait-for-postgres` initContainer** on DB-dependent services: the app opens its DB pool
   once at boot; a pod that starts before Postgres skipped schema init and hung on `/readyz`
   forever (liveness `/healthz` stays 200, so k8s never restarts it). The initContainer makes
   deploy ordering deterministic.
5. **frontend proxy upstream must be an FQDN:** nginx's `resolver` directive ignores
   `/etc/resolv.conf` search domains, so `proxy_pass http://api-gateway` failed
   (`Host not found` → 502). Set `API_GATEWAY_URL=http://api-gateway.$(POD_NAMESPACE).svc.cluster.local`
   (POD_NAMESPACE via downward API; chart stays namespace-agnostic) and extended the deployment
   template to render env `valueFrom`.

---

## Task 3 — In-cluster E2E (the deliverable) — VERIFIED

Port-forwarded `svc/frontend`; order flow works end-to-end through the frontend:
`healthz 200`, `/api/products` → 5, `POST /api/orders {productId:p1,quantity:2}` → **201**.
Generated a burst of ~90 mixed requests (`scripts/gen-traffic.sh`); 26 orders created.

### Metrics (Prometheus) — CONFIRMED
Targets: api-gateway, catalog, orders = **Up** (frontend nginx exposes no app metric — expected).
`http_request_duration_seconds` has live series:
```
sum by (service)(rate(http_request_duration_seconds_count[5m])):
  api-gateway  ~0.51 req/s   (7 series)
  catalog      ~0.61 req/s   (5 series)
  orders       ~0.51 req/s   (5 series)
```

### Logs (Loki) — CONFIRMED
`{namespace="dev"} | json` returns per-request JSON access logs; lines carry `trace_id`, e.g.
```
[ztd-capstone-orders] msg="POST /orders 201 9.93ms" trace_id=3731f555f97cbcc58a41a28839737a94
```
Log volume `sum(count_over_time({namespace="dev"}[5m]))` = 805 lines.

### Traces (Tempo) — CONFIRMED
Distributed trace **`1ff72cfeab6af65f76fbc184e207127f`** (root `api-gateway POST /api/orders`),
12 spans spanning **api-gateway → orders → catalog** plus the **DB span**:
```
api-gateway  POST /api/orders   SERVER
api-gateway  POST               CLIENT ─► orders  POST /orders  SERVER
                                          orders  GET           CLIENT ─► catalog  SERVER (/products/p5)
                                          orders  INSERT        CLIENT ─► postgresql (db span)
```

### Grafana dashboards — CONFIRMED (queried through Grafana's datasource proxy)
All 4 custom dashboards provisioned: `ztd-service-red`, `ztd-logs-overview`,
`ztd-traces-overview`, `ztd-cluster-health`; datasources Prometheus(default)/Loki/Tempo.
Via the Grafana proxy: RED request-rate query returns api-gateway/catalog/orders series;
Logs query returns 805 dev lines/5m; Tempo search returns traces. Dashboards populate.

---

## Safety audit
- Every `terraform plan/apply` inspected before apply; final state `0 destroy` of pre-existing
  infra; `terraform plan` now idempotent (**No changes**).
- App confined to `dev`; all pods (incl. postgres) on `workload=platform` nodes; **none** on
  ng-dense. Pre-existing namespaces (default, ingress-nginx, kube-system, kube-public,
  kube-node-lease, local-path-storage) untouched. ng-dense nodegroup untouched.
- Postgres credentials only in the TF-managed Secret; never committed.

### Recovery note
The first two `terraform apply`s timed out on the helm readiness wait because of the
`:8080`-vs-80 port bug (orders/gateway never went Ready), leaving the release in
`pending-install` + a stale TF state lock. Recovered with `terraform force-unlock`, a one-time
`helm uninstall` of the stuck release (my own release, created this task), then a clean apply
with the fixed chart. Final release is terraform-authoritative (revision managed by TF), plan
idempotent.

---

## Commits (author SaiPisey2 <piseysai0202@gmail.com>, no Claude attribution)
- `57ac7c5` feat(scripts): build-and-push images to ECR (linux/amd64)
- `444bbc5` fix(helm): service-port URLs, correct OTLP endpoint, catalog allowFrom orders, wait-for-postgres init
- `ca3d444` feat(tf-stack): deploy app chart + postgres secret to dev
- `4531098` fix(helm): frontend proxy upstream must be FQDN for nginx resolver
- `<this>`  test(app): in-cluster E2E verification (report + gen-traffic)

## Exit criteria — MET
Four amd64 images in ECR; app + Postgres Running in `dev` on platform nodes (none on ng-dense);
in-cluster order flow works; metrics/logs/traces all flowing into Prometheus/Loki/Tempo and
visible in Grafana; `terraform plan` idempotent. Ready for Phase 7 (CI/CD + OIDC + SonarQube).
