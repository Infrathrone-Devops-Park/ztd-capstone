# Phase 3 — Helm Umbrella Chart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A single production-grade Helm chart `deploy/helm/ztd-capstone` that deploys all four services + Postgres to Kubernetes, with per-environment values (dev/staging/prod), and every production concern wired: resource requests/limits, probes, HPA, PodDisruptionBudget, NetworkPolicies (default-deny + explicit allows), ServiceMonitors for Prometheus, an Ingress for the frontend, non-root securityContext, and image pull from ECR. Validated by `helm lint`, `helm template`, and Kubernetes schema validation — NOT deployed yet (real deploy is Phase 4 on the nodegroup created there).

**Architecture:** One chart, values-driven. `.Values.services.<name>` describes each service (image, port, replicas, resources, HPA, dependencies for NetworkPolicy). Templates render Deployment + Service + HPA + PDB + ServiceMonitor + NetworkPolicy per service by ranging over `.Values.services`. Postgres is a separate StatefulSet template (single template, not the service loop). One Ingress routes the app hostname to the frontend Service. A default-deny NetworkPolicy plus per-service allow rules implement zero-trust networking.

**Tech Stack:** Helm 3, Kubernetes 1.31, Prometheus Operator CRDs (ServiceMonitor), ingress-nginx (already in cluster), kubeconform for offline schema validation.

## Global Constraints

_Every task's requirements implicitly include this section._

- **⚠️ EXISTING-INFRA PROTECTION:** this phase does NOT deploy to the cluster. Validation is offline only: `helm lint`, `helm template`, `kubeconform`, and `kubectl apply --dry-run=client` (client-side, no API writes). Do NOT run `helm install`/`upgrade` or any server-side apply against ztd-demo in this phase. If any command would contact the cluster API to mutate state, do not run it.
- **Namespaces:** the chart is installed into a caller-provided namespace (`dev`/`staging`/`prod`); templates must NOT hardcode a namespace and must NEVER target `default`, `kube-system`, `ingress-nginx`, `local-path-storage`.
- **Images:** `.Values.image.registry` default `514422154867.dkr.ecr.ap-south-1.amazonaws.com`, repo `ztd-capstone/<service>`, tag from `.Values.image.tag` (default `dev`). `imagePullPolicy: IfNotPresent`.
- **Ports:** every service container listens on `8080` (matches Phase 2). Metrics scraped from `/metrics` on the same port. Health `/healthz`, ready `/readyz` (frontend: `/healthz` only).
- **Security:** every pod `securityContext`: `runAsNonRoot: true`, `runAsUser`/`fsGroup` set, `seccompProfile: RuntimeDefault`; container `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` (with emptyDir for writable paths where needed — e.g. nginx temp, tmp), `capabilities: drop: [ALL]`.
- **Scheduling:** all app pods set `nodeSelector: { workload: platform }` (the Phase 4 nodegroup label) so they land on the dedicated nodegroup, never the shared base nodes. Tolerations if the nodegroup is tainted (values-driven, default none).
- **Commits:** authored as `SaiPisey2 <piseysai0202@gmail.com>`. NO Claude attribution.
- **Secrets:** no secrets in the chart. Postgres credentials and app secrets come from a Kubernetes Secret created at deploy time (Phase 4/CI). The chart references secret names via values; `.env`-style values are never committed.

---

## File Structure

```
deploy/helm/ztd-capstone/
├── Chart.yaml
├── values.yaml                 # defaults (all services, resources, HPA, etc.)
├── values-dev.yaml             # dev overrides (1 replica, low resources, debug)
├── values-staging.yaml         # staging overrides
├── values-prod.yaml            # prod overrides (2+ replicas, HPA on, PDB, tighter)
├── .helmignore
├── templates/
│   ├── _helpers.tpl            # name/label/selector helpers, image ref helper
│   ├── NOTES.txt               # post-install usage notes
│   ├── serviceaccount.yaml     # one SA per service (for IRSA later if needed)
│   ├── deployment.yaml         # range .Values.services → Deployment each
│   ├── service.yaml            # range → Service each
│   ├── hpa.yaml                # range → HPA each (when .hpa.enabled)
│   ├── pdb.yaml                # range → PDB each (when replicas>1 / .pdb.enabled)
│   ├── servicemonitor.yaml     # range → ServiceMonitor each (when .metrics.enabled)
│   ├── networkpolicy.yaml      # default-deny + per-service allow rules
│   ├── postgres-statefulset.yaml  # Postgres StatefulSet + headless Service + PVC
│   └── ingress.yaml            # frontend Ingress (ingress-nginx class)
└── ci/
    └── test-values.yaml        # values used for helm template validation in tests
```

---

### Task 1: Chart skeleton, helpers, values schema

**Files:** `Chart.yaml`, `values.yaml`, `values-{dev,staging,prod}.yaml`, `.helmignore`, `templates/_helpers.tpl`, `templates/NOTES.txt`, `ci/test-values.yaml`.

**Interfaces:**
- Produces `.Values.services` map — each entry: `{ image: {repo, tagOverride?}, port, replicas, resources{requests,limits}, hpa{enabled,minReplicas,maxReplicas,targetCPU}, pdb{enabled,minAvailable}, metrics{enabled,path}, ready{path}, live{path}, env[], allowFrom[] (service names permitted to call it), allowEgressTo[] }`. Global `.Values.image.{registry,tag,pullPolicy}`, `.Values.nodeSelector`, `.Values.postgres{...}`, `.Values.ingress{...}`.
- Helper `ztd.image` renders `registry/repo:tag`; `ztd.labels`/`ztd.selectorLabels` render standard labels.

- [ ] **Step 1: Write `Chart.yaml`** — apiVersion v2, name `ztd-capstone`, type application, version 0.1.0, appVersion "1.0.0", description.
- [ ] **Step 2: Write `_helpers.tpl`** — `ztd.name`, `ztd.fullname`, `ztd.labels` (include `app.kubernetes.io/*` + `project: ztd-capstone`), `ztd.selectorLabels`, `ztd.serviceLabels`, and `ztd.image` (registry/repo:tag with per-service tag override).
- [ ] **Step 3: Write `values.yaml`** — global image block; `nodeSelector: {workload: platform}`; the four services under `.Values.services` (frontend, api-gateway, orders, catalog) with sane defaults (frontend/gateway ready `/healthz`+`/readyz` except frontend `/healthz` only; catalog no deps; orders allowFrom [api-gateway], allowEgressTo [catalog, postgres]; api-gateway allowFrom [frontend], allowEgressTo [catalog, orders]; frontend allowFrom [ingress], allowEgressTo [api-gateway]); resources (requests 50m/64Mi, limits 200m/128Mi as starting point, orders a bit higher); hpa disabled by default; metrics enabled path `/metrics`; env wiring (CATALOG_URL, ORDERS_URL, API_GATEWAY_URL, OTEL_EXPORTER_OTLP_ENDPOINT, DATABASE_URL from secret); postgres block; ingress block (enabled, className nginx, host).
- [ ] **Step 4: Write env overrides** — `values-dev.yaml` (image.tag dev, 1 replica, hpa off, ingress host dev.<...>), `values-staging.yaml` (tag staging, 2 replicas), `values-prod.yaml` (tag prod, 2-3 replicas, hpa enabled, pdb enabled, higher limits).
- [ ] **Step 5: Write `.helmignore`, `NOTES.txt`, `ci/test-values.yaml`** (test-values pins a concrete tag + enables everything so templates render fully).
- [ ] **Step 6: Validate** — `helm lint deploy/helm/ztd-capstone -f deploy/helm/ztd-capstone/ci/test-values.yaml` → 0 failures.
- [ ] **Step 7: Commit** — `feat(helm): chart skeleton, values schema, helpers`.

---

### Task 2: Workload templates — Deployment, Service, ServiceAccount

**Files:** `templates/serviceaccount.yaml`, `templates/deployment.yaml`, `templates/service.yaml`.

**Interfaces:**
- Consumes `.Values.services`, `.Values.image`, `.Values.nodeSelector`, helpers.
- Produces one Deployment + Service + ServiceAccount per service, with probes, resources, securityContext, env, and Prometheus scrape-ready pod annotations/labels.

- [ ] **Step 1: `serviceaccount.yaml`** — range services → one SA each (`{{ $fullname }}-{{ $svc }}`), labeled.
- [ ] **Step 2: `deployment.yaml`** — range services: metadata+labels; replicas from env values; selector matchLabels; pod template with: serviceAccountName, `nodeSelector` merged, pod-level securityContext (runAsNonRoot, fsGroup, seccomp RuntimeDefault), one container (name svc, image via `ztd.image`, port 8080, env from `.env` list + rendered dependency URLs, `DATABASE_URL` via `valueFrom.secretKeyRef` for orders, resources, container securityContext readOnlyRootFilesystem + drop ALL + no-priv-escalation, liveness `GET .live.path :8080`, readiness `GET .ready.path :8080`), and emptyDir volumes for writable paths (`/tmp`; nginx needs `/var/cache/nginx`,`/var/run` — frontend-specific, values-driven `writableePaths`). Add checksum/config annotation only if a config template exists (skip if none).
- [ ] **Step 3: `service.yaml`** — range services → ClusterIP Service, port 80→targetPort 8080 named `http`, selector = selectorLabels+service.
- [ ] **Step 4: Validate render** — `helm template t deploy/helm/ztd-capstone -f .../ci/test-values.yaml > /tmp/rendered.yaml`; assert 4 Deployments + 4 Services + 4 SAs present (`grep -c 'kind: Deployment'` == 4, etc.). Pipe through `kubeconform -strict -ignore-missing-schemas` → 0 errors. Also `kubectl apply --dry-run=client -f /tmp/rendered.yaml` (client-side only) succeeds.
- [ ] **Step 5: Commit** — `feat(helm): deployment, service, serviceaccount templates`.

---

### Task 3: Reliability templates — HPA, PDB

**Files:** `templates/hpa.yaml`, `templates/pdb.yaml`.

**Interfaces:** consumes `.Values.services.<>.hpa` and `.pdb`. Produces HPA (autoscaling/v2) + PDB (policy/v1) per service where enabled.

- [ ] **Step 1: `hpa.yaml`** — range services where `.hpa.enabled`: HPA v2 targeting the Deployment, minReplicas/maxReplicas, CPU utilization metric = `.hpa.targetCPU`.
- [ ] **Step 2: `pdb.yaml`** — range services where `.pdb.enabled`: PDB with `minAvailable` from values, selector = service's selectorLabels.
- [ ] **Step 3: Validate** — render with prod values (`-f values.yaml -f values-prod.yaml`): assert HPAs + PDBs appear; render with dev values: assert they do NOT (dev disables). kubeconform clean.
- [ ] **Step 4: Commit** — `feat(helm): HPA and PodDisruptionBudget templates`.

---

### Task 4: Prometheus ServiceMonitors

**Files:** `templates/servicemonitor.yaml`.

**Interfaces:** consumes `.Values.services.<>.metrics`. Produces a `monitoring.coreos.com/v1` ServiceMonitor per service scraping `/metrics` on the `http` port.

- [ ] **Step 1: `servicemonitor.yaml`** — range services where `.metrics.enabled`: ServiceMonitor selecting the service's Service, endpoint port `http`, path `.metrics.path`, interval 30s. Guard the whole file behind `.Values.metrics.serviceMonitor.enabled` (default true) so it can be disabled when the Prometheus Operator CRD is absent.
- [ ] **Step 2: Validate** — render: assert 4 ServiceMonitors. Since the CRD is custom, run `kubeconform -ignore-missing-schemas` (won't have the schema; ensure no other errors). Confirm `helm template` with `metrics.serviceMonitor.enabled=false` emits none.
- [ ] **Step 3: Commit** — `feat(helm): Prometheus ServiceMonitors`.

---

### Task 5: Postgres StatefulSet + headless Service

**Files:** `templates/postgres-statefulset.yaml`.

**Interfaces:** consumes `.Values.postgres` (image postgres:16, storageClass gp2, size, resources, secret name for password, db/user). Produces a StatefulSet (1 replica), a headless Service `postgres` on 5432, volumeClaimTemplate (gp2). Guarded by `.Values.postgres.enabled`.

- [ ] **Step 1: `postgres-statefulset.yaml`** — headless Service `postgres`:5432; StatefulSet with 1 replica, postgres:16 container, env `POSTGRES_DB`/`POSTGRES_USER` from values, `POSTGRES_PASSWORD` from `secretKeyRef` (secret name from values), PGDATA subPath, readiness/liveness via `pg_isready`, resources, securityContext (postgres runs as uid 999 non-root, fsGroup), volumeClaimTemplate storageClassName `gp2` size from values. nodeSelector workload=platform.
- [ ] **Step 2: Validate** — render: assert 1 StatefulSet + headless Service; kubeconform strict clean; dry-run client OK. Confirm `orders` DATABASE_URL host `postgres` matches the headless Service name.
- [ ] **Step 3: Commit** — `feat(helm): Postgres StatefulSet with gp2 PVC`.

---

### Task 6: NetworkPolicies (zero-trust) + Ingress

**Files:** `templates/networkpolicy.yaml`, `templates/ingress.yaml`.

**Interfaces:** consumes `.Values.services.<>.allowFrom`/`.allowEgressTo`, `.Values.ingress`. Produces a default-deny-ingress policy for the namespace, per-service allow-ingress rules from named peers, DNS egress allow, and a frontend Ingress.

- [ ] **Step 1: `networkpolicy.yaml`** —
  - Default-deny: a NetworkPolicy selecting all pods, `policyTypes: [Ingress]`, empty ingress (deny all inbound by default).
  - Per service: allow ingress on 8080 from pods matching each name in `.allowFrom` (translate service name → podSelector on selectorLabels; special-case `ingress` → from `ingress-nginx` namespace via namespaceSelector on label `kubernetes.io/metadata.name: ingress-nginx`).
  - Egress: allow DNS (UDP/TCP 53 to kube-system) for all pods, plus per-service egress to `.allowEgressTo` targets on 8080 and to postgres on 5432. (policyTypes Egress on those.)
  - Guard behind `.Values.networkPolicy.enabled` (default true).
- [ ] **Step 2: `ingress.yaml`** — guarded by `.Values.ingress.enabled`: Ingress with `ingressClassName: nginx`, host from values, path `/` → frontend Service port 80, annotations for ingress-nginx (proxy body size etc.). TLS block values-driven (optional, default off).
- [ ] **Step 3: Validate** — render full chart with test-values: assert default-deny NP + per-service NPs + 1 Ingress; kubeconform strict (NetworkPolicy + Ingress are core → schema exists) → 0 errors; dry-run client OK. Verify the `ingress` peer produces a namespaceSelector for `ingress-nginx` (so it works with the EXISTING controller without modifying it).
- [ ] **Step 4: Commit** — `feat(helm): zero-trust NetworkPolicies and frontend Ingress`.

---

### Task 7: Full-chart validation gate

**Files:** none (validation only); optionally a `Makefile`/script `deploy/helm/validate.sh`.

- [ ] **Step 1: Lint all envs** — `helm lint deploy/helm/ztd-capstone -f values.yaml -f values-dev.yaml`; repeat for staging, prod. All 0 failures.
- [ ] **Step 2: Template + schema-validate all envs** — for each env: `helm template ztd deploy/helm/ztd-capstone -f values.yaml -f values-<env>.yaml -n <env> | kubeconform -strict -ignore-missing-schemas -summary`. 0 errors each. Assert prod render contains HPAs+PDBs, dev does not.
- [ ] **Step 2b: Client dry-run** — pipe each env's render to `kubectl apply --dry-run=client -f -` (no cluster mutation). Succeeds.
- [ ] **Step 3: Optional `validate.sh`** — script running steps 1–2b for CI reuse (Phase 6 will call it).
- [ ] **Step 4: Commit** — `chore(helm): full-chart validation script and gate`.

---

## Self-Review

- **Spec coverage:** Implements spec §4 (chart layout), §7 (HPA, PDB, NetworkPolicies, probes, securityContext, resource limits), §6 (ServiceMonitors feed Prometheus), §3 (Postgres). Per-env values realize dev/staging/prod namespaces (spec §5 branching → envs). nodeSelector `workload=platform` ties pods to the Phase 4 nodegroup, protecting the shared base nodes.
- **Placeholder scan:** none — each template's contents and validation commands are concrete. (Full template bodies are delegated to implementers by contract, consistent with Phase 2's documented rationale; interfaces/labels/guards are specified exactly.)
- **Interface consistency:** port 8080 and `/metrics`,`/healthz`,`/readyz` match Phase 2 contracts; `postgres` headless Service name matches orders' `DATABASE_URL`; NetworkPolicy `ingress` peer targets the existing `ingress-nginx` namespace without modifying it.
- **Safety:** no server-side cluster calls this phase; validation is lint/template/kubeconform/dry-run-client only.

## Phase Exit Criteria

- Chart lints clean for dev/staging/prod; all envs template and pass kubeconform + client dry-run.
- Prod render includes HPAs, PDBs, ServiceMonitors, default-deny + allow NetworkPolicies, Postgres StatefulSet, Ingress; dev render is appropriately reduced.
- No cluster mutation occurred. Commits authored SaiPisey2, no Claude attribution, pushed to main.
- Chart ready for Phase 4 to `helm upgrade --install` onto the new nodegroup.
