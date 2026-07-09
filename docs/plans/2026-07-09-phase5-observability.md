# Phase 5 — Observability Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Install the full observability stack into the `observability` namespace on the dedicated platform nodegroup, via Terraform `helm_release` resources (so it comes up with `terraform apply`), with all values + Grafana datasources + dashboards committed to git: Prometheus + Grafana + node-exporter + kube-state-metrics (kube-prometheus-stack), Loki + Promtail (logs), Tempo + OpenTelemetry Collector (traces). Grafana is pre-provisioned with Prometheus/Loki/Tempo datasources and four dashboards.

**Architecture:** App pods expose `/metrics` (scraped by Prometheus via ServiceMonitors from the Phase 3 chart), write JSON logs to stdout (tailed by Promtail → Loki), and send OTLP traces to the OpenTelemetry Collector → Tempo. Grafana queries all three backends with trace↔log correlation. Every observability component — including the node-exporter and Promtail DaemonSets — is constrained to `nodeSelector: {workload: platform}` so **nothing schedules onto the shared `ng-dense` nodes**.

**Tech Stack:** Terraform helm provider, Helm charts (kube-prometheus-stack, loki, promtail, tempo, opentelemetry-collector), Prometheus, Grafana, Loki, Tempo, OpenTelemetry Collector, gp2 PVCs.

## Global Constraints

_Every task's requirements implicitly include this section._

- **AWS/cluster:** profile `infrathrone-new`, region `ap-south-1`, cluster `ztd-demo`. Terraform root: `terraform/stack/` (S3 backend already configured; helm/kubernetes providers already wired in Phase 4).
- **⚠️ EXISTING-INFRA PROTECTION:**
  - Everything installs into the **`observability` namespace only** (created in Phase 4). Never touch default/kube-system/ingress-nginx/local-path-storage/kube-public/kube-node-lease.
  - **ALL observability workloads, including DaemonSets (node-exporter, Promtail), MUST be constrained to `nodeSelector: {workload: platform}`** (and matching tolerations if any) so ZERO observability pods land on the shared `ng-dense` t3.small nodes. This is a hard requirement — verify no obs pod runs on a non-platform node.
  - Do not install any cluster-wide mutating webhook that could affect other namespaces. kube-prometheus-stack's admission webhook for PrometheusRules is namespaced/optional — keep its scope minimal; disable the admission webhook if it would act cluster-wide unnecessarily (prefer `prometheusOperator.admissionWebhooks.enabled=false` OR ensure it only manages our CRs).
  - CRDs (Prometheus Operator, etc.) are cluster-scoped by nature — installing them is acceptable (additive) but do NOT remove/replace any pre-existing CRDs. If a Prometheus Operator CRD already exists in the cluster, STOP and report (avoid clobbering another owner).
- **Capacity:** the platform nodegroup is 2× t3.large (~4 vCPU / ~16 GiB total). Set modest resource requests/limits on every component and short retention (Prometheus 5d, Loki/Tempo filesystem with small retention) so the stack fits with headroom for the app (Phase 6).
- **Persistence:** Prometheus, Loki, Tempo, Grafana use gp2 PVCs (small sizes, e.g. 5–10Gi). AlertManager can be disabled (not required) to save resources.
- **Commits:** `SaiPisey2 <piseysai0202@gmail.com>`. NO Claude attribution.
- **Secrets:** Grafana admin password from a Terraform `random_password` → Kubernetes Secret (not committed); referenced by the Grafana release. No secrets in committed values files.
- **You may `terraform apply` autonomously** after inspecting each plan (confirm additive, `0 to destroy` of anything pre-existing).

---

## File Structure

```
deploy/observability/
├── kube-prometheus-stack.values.yaml   # Prometheus, Grafana, node-exporter, kube-state-metrics
├── loki.values.yaml                    # Loki single-binary + filesystem storage
├── promtail.values.yaml                # Promtail DaemonSet (platform nodes only)
├── tempo.values.yaml                   # Tempo single-binary + OTLP receiver
├── opentelemetry-collector.values.yaml # OTel Collector (OTLP in → Tempo out)
├── datasources/
│   └── datasources.yaml                # Grafana datasources (Prometheus, Loki, Tempo) — provisioned via kube-prometheus-stack values (additionalDataSources)
└── dashboards/
    ├── service-red.json                # RED metrics per service (Prometheus)
    ├── logs-overview.json              # log volume + errors (Loki)
    ├── traces-overview.json            # latency + service map (Tempo)
    └── cluster-health.json             # node/pod health (Prometheus)

terraform/stack/
└── observability.tf                    # helm_release x5 + grafana secret + dashboards configmaps
```

---

### Task 1: kube-prometheus-stack values + Grafana datasources + Prometheus release

**Files:** `deploy/observability/kube-prometheus-stack.values.yaml`, `deploy/observability/datasources/datasources.yaml` (or inline in values), and add the `helm_release.kube_prometheus_stack` + Grafana admin Secret to `terraform/stack/observability.tf`.

**Interfaces:**
- Produces: Prometheus (scrapes ServiceMonitors cluster-wide but we only create them in app namespaces), Grafana (admin secret, datasources for Prometheus+Loki+Tempo, dashboard sidecar enabled), node-exporter + kube-state-metrics. Prometheus Operator CRDs installed. Grafana reachable via port-forward (and optional ingress).

- [ ] **Step 1: `kube-prometheus-stack.values.yaml`** — set:
  - Global `nodeSelector: {workload: platform}` applied to prometheusOperator, prometheus, grafana, kube-state-metrics, and **`nodeExporter.nodeSelector: {workload: platform}`** (so node-exporter DaemonSet runs only on platform nodes).
  - `alertmanager.enabled: false`.
  - `prometheus.prometheusSpec`: `retention: 5d`, `resources` (req 200m/512Mi, lim 500m/1Gi), `storageSpec` gp2 PVC 10Gi, `serviceMonitorSelectorNilUsesHelmValues: false` (so it picks up ServiceMonitors in app namespaces without a release label), `podMonitorSelectorNilUsesHelmValues: false`.
  - `grafana`: `adminPassword` via `admin.existingSecret` (the TF-created secret) OR `grafana.admin.existingSecret`; `nodeSelector`; `persistence` gp2 5Gi; `sidecar.dashboards.enabled: true` (label `grafana_dashboard: "1"`), `sidecar.datasources.enabled: true`; `additionalDataSources` for Loki (`http://loki-gateway.observability` or the loki service) and Tempo (`http://tempo.observability:3100`) with `derivedFields`/trace-to-logs correlation; Prometheus datasource is default from the stack. Resources modest.
  - `prometheusOperator.admissionWebhooks`: minimize/disable if it would be cluster-wide; keep operator scoped.
  - `kube-state-metrics.nodeSelector`, `resources` small.
- [ ] **Step 2: `terraform/stack/observability.tf`** — `random_password.grafana_admin`; `kubernetes_secret.grafana_admin` in observability ns (keys `admin-user=admin`, `admin-password`); `helm_release.kube_prometheus_stack` (repo `https://prometheus-community.github.io/helm-charts`, chart `kube-prometheus-stack`, pinned version, namespace observability, `values = [file(".../kube-prometheus-stack.values.yaml")]`, `timeout = 900`, depends_on the secret). Pin a concrete recent chart version.
- [ ] **Step 3: Plan + apply** — inspect plan (adds CRDs + operator + prometheus + grafana + secret; `0 to destroy`). Before apply, check no conflicting Prometheus Operator CRDs exist: `kubectl get crd | grep monitoring.coreos.com` → expect NONE (if present, STOP). Apply (`timeout` allows CRD + pod startup).
- [ ] **Step 4: Verify** — pods in observability Running; `kubectl -n observability get pods -o wide` shows ALL on t3.large (platform) nodes; Prometheus targets healthy (`kubectl -n observability port-forward svc/<prom> 9090` → /api/v1/targets has node-exporter/kube-state-metrics up); Grafana up (port-forward, login with admin secret, datasources Prometheus/Loki/Tempo present — Loki/Tempo will error until their releases exist, that's expected until Task 3/4).
- [ ] **Step 5: Commit** — `feat(obs): kube-prometheus-stack with Grafana datasources on platform nodes`.

---

### Task 2: Loki + Promtail (logs)

**Files:** `deploy/observability/loki.values.yaml`, `deploy/observability/promtail.values.yaml`; add `helm_release.loki` + `helm_release.promtail` to `observability.tf`.

**Interfaces:** Loki service reachable at `http://loki.observability:3100` (name must match the Grafana datasource URL from Task 1); Promtail ships all pod logs from platform nodes to Loki.

- [ ] **Step 1: `loki.values.yaml`** — Loki in **single-binary** (monolithic) mode: `deploymentMode: SingleBinary`, `loki.commonConfig.replication_factor: 1`, `loki.storage.type: filesystem`, `singleBinary.replicas: 1`, `singleBinary.persistence` gp2 10Gi, `singleBinary.nodeSelector: {workload: platform}`, disable caches/minio, `loki.auth_enabled: false`, small resources, short retention (e.g. 72h via `limits_config.retention_period` + compactor). Ensure the resulting Service name resolves to what Task 1's Tempo/Loki datasource URL expects (align names; adjust the datasource URL in Task 1 if the chart's service is `loki` vs `loki-gateway`).
- [ ] **Step 2: `promtail.values.yaml`** — `daemonset.enabled: true`, **`nodeSelector: {workload: platform}`** (only platform nodes), `config.clients: [{url: http://loki.observability:3100/loki/api/v1/push}]`, pipeline stages to parse JSON logs (extract `trace_id`, `level`, `service`), small resources. (Promtail on platform nodes captures the app + obs pod logs; shared-node logs are intentionally out of scope.)
- [ ] **Step 3: `helm_release.loki` + `helm_release.promtail`** in observability.tf (repo `https://grafana.github.io/helm-charts`, pinned versions, namespace observability, values files). loki before promtail (`depends_on`).
- [ ] **Step 4: Plan + apply** — additive; apply.
- [ ] **Step 5: Verify** — Loki + Promtail pods Running on platform nodes; Promtail DaemonSet has desired == number of PLATFORM nodes (2), NOT total nodes (4) — confirms nodeSelector works; Loki ready (`/ready`); in Grafana the Loki datasource now returns label values (`kubectl port-forward` + query `{namespace="observability"}` returns log lines). Re-confirm no obs pod on ng-dense nodes.
- [ ] **Step 6: Commit** — `feat(obs): Loki + Promtail log pipeline on platform nodes`.

---

### Task 3: Tempo + OpenTelemetry Collector (traces)

**Files:** `deploy/observability/tempo.values.yaml`, `deploy/observability/opentelemetry-collector.values.yaml`; add `helm_release.tempo` + `helm_release.otel_collector` to `observability.tf`.

**Interfaces:** OTel Collector receives OTLP at `http://opentelemetry-collector.observability:4318` (the endpoint apps will use in Phase 6) and exports to Tempo at `tempo.observability:4317`; Tempo queryable by Grafana at `http://tempo.observability:3200`.

- [ ] **Step 1: `tempo.values.yaml`** — Tempo single-binary: `tempo.storage.trace.backend: local`, persistence gp2 10Gi, `nodeSelector: {workload: platform}`, OTLP receivers enabled (grpc 4317 / http 4318), small resources, short retention. Service name must match the Grafana Tempo datasource URL from Task 1 (align).
- [ ] **Step 2: `opentelemetry-collector.values.yaml`** — `mode: deployment`, `nodeSelector: {workload: platform}`, `config.receivers.otlp` (grpc+http), `config.exporters` → OTLP to `tempo.observability:4317` (tls insecure), `config.service.pipelines.traces` receivers [otlp] exporters [otlp/tempo]. (Optionally a logs/metrics pipeline, but traces are the requirement.) Small resources. Ensure the Service is named `opentelemetry-collector` (or set fullnameOverride) so the app OTLP endpoint `http://opentelemetry-collector.observability:4318` resolves.
- [ ] **Step 3: `helm_release.tempo` + `helm_release.otel_collector`** in observability.tf (grafana repo for tempo; `https://open-telemetry.github.io/opentelemetry-helm-charts` for the collector; pinned versions). tempo before collector.
- [ ] **Step 4: Plan + apply** — additive; apply.
- [ ] **Step 5: Verify** — Tempo + Collector pods Running on platform nodes; Collector OTLP ports listening; send a synthetic trace (e.g. `kubectl run` a `telemetrygen` job or curl an OTLP span to the collector) and confirm it lands in Tempo via Grafana Tempo datasource (or `tempo` API). If synthetic trace tooling is heavy, defer full trace validation to Phase 6 (real app traffic) but MUST confirm both pods healthy + collector accepting OTLP (port open) + Tempo ready.
- [ ] **Step 6: Commit** — `feat(obs): Tempo + OpenTelemetry Collector trace pipeline`.

---

### Task 4: Grafana dashboards (committed JSON, auto-provisioned)

**Files:** `deploy/observability/dashboards/{service-red,logs-overview,traces-overview,cluster-health}.json`; add `kubernetes_config_map` resources (labeled `grafana_dashboard: "1"`) in `observability.tf` OR mount via the values sidecar.

**Interfaces:** four dashboards appear in Grafana automatically via the sidecar.

- [ ] **Step 1: Author the four dashboards** as Grafana dashboard JSON:
  - `service-red.json` — per-service request rate, error rate, p50/p95/p99 duration from `http_request_duration_seconds` (Prometheus); template variable `service`.
  - `logs-overview.json` — log volume over time + error-level log stream, filter by `service` (Loki `{service=~"$service"} | json`).
  - `traces-overview.json` — trace latency distribution + a Tempo service-graph/search panel (Tempo datasource).
  - `cluster-health.json` — platform-node CPU/mem/pod count, pod restarts (Prometheus, filtered to platform nodes / observability+app namespaces).
- [ ] **Step 2: Provision** — for each JSON, a `kubernetes_config_map` in observability ns with label `grafana_dashboard: "1"` and the JSON under `data`, OR reference them via the Grafana sidecar `dashboards` config. (ConfigMap-per-dashboard is simplest and keeps JSON in git.)
- [ ] **Step 3: Plan + apply** — additive; apply.
- [ ] **Step 4: Verify** — `kubectl -n observability get cm -l grafana_dashboard=1` shows 4; Grafana (port-forward) → the 4 dashboards appear under a folder; panels render (Prometheus panels show data; Loki panel shows obs logs; Tempo panel loads — trace data may be empty until Phase 6, that's OK; assert the dashboards exist and their datasources resolve without error).
- [ ] **Step 5: Commit** — `feat(obs): Grafana dashboards (RED, logs, traces, cluster health)`.

---

### Task 5: Full observability verification + idempotency

- [ ] **Step 1: Plan idempotent** — `terraform plan` → "No changes."
- [ ] **Step 2: Placement audit (hard requirement)** — `kubectl -n observability get pods -o wide` → EVERY pod on a `workload=platform` (t3.large) node; NONE on the two t3.small ng-dense nodes. Also `kubectl get pods -A -o wide | grep -E 'ip-192-168-6-232|ip-192-168-91-64'` (the ng-dense node names) shows NO ztd-capstone/observability pods added by us.
- [ ] **Step 3: Health summary** — all observability pods Running/Ready; Prometheus targets up; Loki + Tempo ready; Grafana datasources green (Prometheus, Loki; Tempo green even if empty); 4 dashboards present.
- [ ] **Step 4: ng-dense + cluster safety re-audit** — ng-dense unchanged; original namespaces intact.
- [ ] **Step 5: Commit + push** — `chore(obs): observability verification` and push all Phase 5 commits.

---

## Self-Review

- **Spec coverage:** Implements spec §6 (Prometheus+Grafana, Loki+Promtail, Tempo+OTel, 4 dashboards, all configs in git) and the single-`apply` requirement (helm_release in the stack root). Datasource URLs align with the app's Phase 6 OTLP endpoint.
- **Placeholder scan:** none — concrete values, releases, verification. Exact chart values are delegated to the implementer (must pin real chart versions and align service names between datasource URLs and the charts' actual Service names).
- **Interface consistency:** app OTLP endpoint `http://opentelemetry-collector.observability:4318` (Phase 6 will set this on app pods) matches the collector Service; Loki/Tempo datasource URLs match their Service names; `workload=platform` nodeSelector matches the Phase 4 nodegroup label; ServiceMonitor pickup enabled matches the Phase 3 chart's ServiceMonitors.
- **Safety:** all workloads (incl. DaemonSets) pinned to platform nodes; CRD-conflict check before install; additive-only applies; placement audit ensures zero footprint on shared nodes.

## Phase Exit Criteria

- Observability stack Running entirely on the platform nodegroup (verified: no obs pod on ng-dense nodes).
- Grafana provisioned with Prometheus/Loki/Tempo datasources + 4 dashboards, all from git.
- Prometheus scraping, Loki ingesting obs logs, Tempo + OTel Collector ready to receive app traces.
- `terraform plan` idempotent; ng-dense + cluster unchanged; commits authored SaiPisey2, pushed.
- Ready for Phase 6 (deploy the app → traces/logs/metrics flow end-to-end into these dashboards).
