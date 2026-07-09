# Phase 6 — App Deploy to EKS + In-Cluster E2E — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build and push the four service images to ECR (linux/amd64), then deploy the app via a Terraform `helm_release` of the Phase 3 chart into the `dev` namespace, and verify end-to-end in the real cluster: the order flow works, and metrics, logs, and traces from the running app land in Prometheus, Loki, and Tempo and show up in the Grafana dashboards.

**Architecture:** Images live in ECR (built by Phase 1's repos). The app chart (Phase 3) deploys onto the platform nodegroup (Phase 4) with a Postgres StatefulSet and a Kubernetes Secret (created by TF). Apps send OTLP to the collector installed in Phase 5 (`http://opentelemetry-collector.observability:4318`), expose `/metrics` scraped by Prometheus via the chart's ServiceMonitors, and write JSON logs tailed by Promtail. Deploying via `helm_release` in `terraform/stack/` keeps the single-`terraform apply` property.

**Tech Stack:** Docker buildx (amd64), ECR, Terraform helm/kubernetes providers, Helm, the Phase 3 chart, Prometheus/Loki/Tempo/Grafana (Phase 5).

## Global Constraints

_Every task's requirements implicitly include this section._

- **AWS/cluster:** profile `infrathrone-new`, account `514422154867`, region `ap-south-1`, cluster `ztd-demo`. ECR registry `514422154867.dkr.ecr.ap-south-1.amazonaws.com`, repos `ztd-capstone/{frontend,api-gateway,orders,catalog}` (tag mutability IMMUTABLE → use a unique tag).
- **⚠️ EXISTING-INFRA PROTECTION:** app deploys into the **`dev` namespace only** (Phase 4). App + Postgres pods MUST land on `workload=platform` nodes (chart already sets nodeSelector). Verify no app pod on ng-dense nodes. Every `terraform plan` additive with `0 to destroy` of pre-existing infra; inspect before apply.
- **Image tag:** use the current git short SHA as the immutable tag (e.g. `sha-<7hex>`). All four images share the tag. Set `.Values.image.tag` to it.
- **Host is arm64; cluster is amd64** → build with `docker buildx build --platform linux/amd64 --push`. Confirm pushed manifests are amd64.
- **Secrets:** the `ztd-capstone-postgres` Secret (keys `postgres-password`, `database-url`) is created by Terraform `kubernetes_secret` from a `random_password`, in the `dev` namespace — never committed. `database-url` = `postgresql://ztd:<pw>@postgres:5432/ztd`.
- **Commits:** `SaiPisey2 <piseysai0202@gmail.com>`. NO Claude attribution.
- **You may `terraform apply` autonomously** after the plan-inspection gate.

---

## File Structure

```
terraform/stack/
├── app.tf                 # kubernetes_secret (postgres) + helm_release.app (chart → dev ns)
scripts/
└── build-push-images.sh   # buildx build+push the 4 images to ECR with a tag arg
deploy/helm/ztd-capstone/
└── values-dev.yaml        # (Phase 3) — may need image.tag wired to a TF-set value
```

---

### Task 1: Build + push images to ECR

**Files:** `scripts/build-push-images.sh`.

**Interfaces:** produces four `linux/amd64` images in ECR tagged `sha-<gitsha>`.

- [ ] **Step 1: `scripts/build-push-images.sh`** — bash: takes a TAG arg (default current git short sha `sha-$(git rev-parse --short HEAD)`); `aws ecr get-login-password | docker login`; for each service in frontend,api-gateway,orders,catalog: `docker buildx build --platform linux/amd64 -t <registry>/ztd-capstone/<svc>:<TAG> --push services/<svc>`. Ensure a buildx builder exists (`docker buildx create --use` if needed). Print the pushed tag at the end.
- [ ] **Step 2: Run it** — `AWS_PROFILE=infrathrone-new ./scripts/build-push-images.sh`. (amd64 builds under QEMU emulation are slow — allow time.)
- [ ] **Step 3: Verify in ECR** — for each repo, `aws ecr describe-images --repository-name ztd-capstone/<svc> --image-ids imageTag=<TAG>` returns the image; check `imageManifest`/architecture is amd64 (`aws ecr batch-get-image` or `docker buildx imagetools inspect <registry>/ztd-capstone/<svc>:<TAG>` shows `linux/amd64`).
- [ ] **Step 4: Commit** — `feat(scripts): build-and-push images to ECR (linux/amd64)`.

---

### Task 2: Terraform app deploy (secret + helm_release)

**Files:** `terraform/stack/app.tf`; possibly a `var.app_image_tag` in `variables.tf`.

**Interfaces:** deploys the chart into `dev` with the pushed image tag; produces the running app.

- [ ] **Step 1: `variables.tf`** — add `variable "app_image_tag"` (string, no default OR default to a documented tag) and `variable "app_deploy_enabled"` (bool default true) so the app release can be toggled.
- [ ] **Step 2: `app.tf`** —
  - `random_password.postgres` (length 20, special false).
  - `kubernetes_secret.postgres` in `dev` ns, name `ztd-capstone-postgres`, data `postgres-password` = the password, `database-url` = `postgresql://ztd:${pw}@postgres:5432/ztd`.
  - `helm_release.app`: chart = local path `${path.module}/../../deploy/helm/ztd-capstone`, namespace `dev`, values = [file(values.yaml), file(values-dev.yaml)], `set { name = "image.tag" value = var.app_image_tag }`, depends_on the secret + the kube-prometheus-stack release (so ServiceMonitor CRD exists), timeout 600.
- [ ] **Step 3: Plan + apply** — `terraform plan` (set `-var app_image_tag=sha-<gitsha>`); inspect (adds secret + app release; `0 to destroy`); apply autonomously.
- [ ] **Step 4: Verify rollout** — `kubectl -n dev get pods -o wide`: frontend, api-gateway, orders, catalog, postgres all Running/Ready on platform nodes; none on ng-dense. `kubectl -n dev get svc,ingress,servicemonitor,networkpolicy` present. Check orders connected to postgres (logs show schema init, `/readyz` 200).
- [ ] **Step 5: Commit** — `feat(tf-stack): deploy app chart + postgres secret to dev`.

---

### Task 3: In-cluster end-to-end verification (the phase deliverable)

**Files:** none (verification); optionally `scripts/gen-traffic.sh`.

- [ ] **Step 1: Exercise the order flow in-cluster** — port-forward the frontend (or api-gateway) service and run the same smoke as Phase 2 against the cluster:
  ```bash
  kubectl -n dev port-forward svc/<frontend> 8080:80 &
  curl -s localhost:8080/healthz            # ok
  curl -s localhost:8080/api/products | jq 'length'   # >=5
  curl -s -XPOST localhost:8080/api/orders -H 'content-type: application/json' -d '{"productId":"p1","quantity":2}'  # 201
  curl -s localhost:8080/api/orders | jq 'length'     # >=1
  ```
  Generate a burst of traffic (loop ~50–100 requests across products + orders) so metrics/traces/logs have data.
- [ ] **Step 2: Verify metrics** — Prometheus (port-forward) shows the app targets Up and `http_request_duration_seconds` has series for each service: query `sum by (service)(rate(http_request_duration_seconds_count[5m]))` returns data for frontend? (frontend has none), api-gateway/orders/catalog yes. Confirm ServiceMonitors were scraped (`kubectl -n dev get servicemonitor`; Prometheus `/api/v1/targets` shows dev endpoints Up).
- [ ] **Step 3: Verify logs** — Grafana/Loki: query `{namespace="dev"} | json` returns the per-request JSON access logs from the app; confirm a log line has a `trace_id` field.
- [ ] **Step 4: Verify traces** — Grafana/Tempo: search traces for service `api-gateway` (or `orders`); confirm a distributed trace exists spanning gateway → orders → catalog (and the DB span from orders' psycopg instrumentation). Grab one trace id.
- [ ] **Step 5: Verify dashboards populate** — the RED dashboard shows request rate/latency for the services; the logs dashboard shows dev log volume; the traces dashboard shows the trace/latency. Capture evidence (panel queries returning data / screenshots or API queries).
- [ ] **Step 6: Placement + safety re-audit** — no app pod on ng-dense; ng-dense + original namespaces unchanged; `terraform plan` idempotent.
- [ ] **Step 7: Commit + push** — `test(app): in-cluster E2E verification` (+ any gen-traffic script). Push all Phase 6 commits.

---

## Self-Review

- **Spec coverage:** Realizes spec §3/§4/§6 in the real cluster — the app running on EKS with metrics, logs, and traces flowing into the Phase 5 stack and dashboards. Deploy via helm_release keeps spec §5's single-apply property. Uses ECR (spec registry decision).
- **Placeholder scan:** none — concrete build/push, TF resources, and verification queries.
- **Interface consistency:** OTLP endpoint matches Phase 5 collector service; postgres Secret name + `database-url` host `postgres` match the Phase 3 chart's `DATABASE_URL` secretKeyRef and the headless Service; image tag flows from build → `var.app_image_tag` → chart `image.tag`; ServiceMonitors match Prometheus's cross-namespace scraping from Phase 5.
- **Safety:** app in dev ns only, on platform nodes; additive applies; placement + ng-dense audit.

## Phase Exit Criteria

- Four amd64 images in ECR; app (incl. Postgres) Running in `dev` on platform nodes; none on ng-dense.
- In-cluster order flow works; `http_request_duration_seconds` in Prometheus, JSON logs (with trace_id) in Loki, a distributed trace (gateway→orders→catalog→db) in Tempo — all visible in the Grafana dashboards.
- `terraform plan` idempotent; ng-dense + cluster unchanged; commits authored SaiPisey2, pushed.
- Ready for Phase 7 (CI/CD workflows + OIDC + SonarQube integration that automate this build→scan→push→deploy).
