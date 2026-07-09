# ztd-capstone progress ledger

## Phase 1 — Foundation & Bootstrap Terraform
Plan: docs/plans/2026-07-09-phase1-foundation-bootstrap.md
Status: in progress
Task 1-6: complete (commits 279f847..HEAD, review clean, spec ✅ / quality approved)
Post-review fix: ECR force_delete=true (enables full teardown per user goal)
Phase 1: COMPLETE. Bootstrap live (S3 state, DynamoDB lock, 4 ECR repos). Cluster untouched.

## Phase 2 — App services
Plan: docs/plans/2026-07-09-phase2-app-services.md
Task 1 catalog (Go): complete (b307fc7 + fix 43a9bf9, 8/8 tests, review addressed). Contract: /products p1..p5, :8080, http_request_duration_seconds.
Task 2 api-gateway (Fastify): complete (4e32899, 13/13 tests, spec ✅ quality approved). Contract: /api/products, /api/products/:id, POST /api/orders, GET /api/orders, :8080.
  Minor nits (final-review triage): unused @fastify/sensible dep; err.message leak in 502 body; 404 route label falls back to raw path (cardinality).
Task 3 orders (FastAPI): complete (0af4a15 + fix e290a90, 14 tests, spec ✅ quality approved). Contract: POST/GET /orders, /orders/{id}, :8080, Postgres, catalog validate. psycopg spans live-verified.
Task 4 frontend (React+Nginx): complete (19d5dd1 + fix c748a88, spec ✅ quality approved). Nginx :8080, /healthz, /api proxy, resolver derived from resolv.conf (k8s-portable).
Task 5 docker-compose E2E: complete (bf5ff98 + fix 7864180). FULL STACK E2E PASSES: browse->order->201, distributed trace gateway->orders->catalog, metrics exposed. otel-collector distroless so no container HEALTHCHECK; real health_check ext on :13133.
Phase 2: COMPLETE. 4 polyglot services + Postgres + otel-collector, local E2E verified. Contracts locked for Phase 3 (Helm).
  Deferred minors for final review: gateway unused @fastify/sensible dep, gateway 502 err.message leak, gateway 404 route-label cardinality.

## Phase 3 — Helm chart
Plan: docs/plans/2026-07-09-phase3-helm-chart.md
Chart deploy/helm/ztd-capstone: COMPLETE (9e633ef..7fa9cfe). Offline-validated lint+kubeconform+dry-run all 3 envs. Review caught 2 Critical (postgres netpol unreachable, dotted volume name) + orders UID — all fixed.
Phase 4 carry-ins: chart references but does NOT create ztd-capstone-postgres Secret (TF/CI must); non-orders runAsUser image-inferred (verify on 1st deploy); ingress hosts placeholders.
Phase 3: COMPLETE.

## Phase 4 — Stack Terraform
Plan: docs/plans/2026-07-09-phase4-stack-terraform.md
COMPLETE (49c254a..7da236f). Applied + verified:
- nodegroup ztd-capstone-platform: 2x t3.large, workload=platform, Ready. ng-dense UNTOUCHED (t3.small 2/2/3 ACTIVE).
- SonarQube EC2 i-0731ac9e31024af77, EIP 13.200.32.13, http://13.200.32.13:9000 status UP (v26.7.0). SSM Online, 9000 open 0.0.0.0/0 (USER-APPROVED). DB pass in SSM /ztd-capstone/sonar/db-password.
- Namespaces dev/staging/prod/observability created; 6 originals intact.
- terraform plan idempotent. Sonar SG sg-0e68c8d4f1e047c61.
Phase 4: COMPLETE. Note: security review of stack TF pending.
Review of stack TF: Spec ✅, teardown clean. 2 Important security findings (IMDSv1, unencrypted EBS) — verified account defaults ALREADY enforce IMDSv2+encryption; pinned explicitly in code (commit after 7da236f). Dead operator_cidr var removed.
Phase 4: fully COMPLETE + reviewed.

## Phase 5 — Observability
Plan: docs/plans/2026-07-09-phase5-observability.md
COMPLETE (d9afd34..1856d32). 11 obs pods ALL on platform nodes, 0 on ng-dense (indep-verified), DaemonSets desired=2, Prometheus 27/27, Loki+Tempo ready, 3 datasources green, 4 dashboards. Review: Spec ✅ Approved (helm-template-verified service names: collector opentelemetry-collector:4318, loki:3100, tempo:3200). ng-dense untouched.
Phase 6 contract: app OTLP -> http://opentelemetry-collector.observability:4318; ServiceMonitors auto-scraped cross-ns.
Phase 5: COMPLETE.

## Phase 6 — App deploy + in-cluster E2E
Plan: docs/plans/2026-07-09-phase6-app-deploy.md
COMPLETE (57ac7c5..HEAD). 4 amd64 images in ECR (tag sha-38e32ab). App live in dev on platform nodes (5/5 pods). LIVE E2E: order 201, metrics (http_request_duration_seconds api-gateway/orders/catalog), Loki logs w/ trace_id, Tempo trace api-gateway->orders->catalog+db span. ng-dense untouched. Idempotent.
5 chart bugs found+fixed by live deploy: inter-svc :8080->Service port 80; OTLP host otel-collector->opentelemetry-collector.observability:4318; catalog allowFrom orders; DB startup-race initContainer; nginx resolver FQDN. Review: Spec ✅ Approved, no regressions.
NOTE: NetworkPolicy NOT enforced on cluster (--enable-network-policy=false).
Phase 6: COMPLETE.

## Phase 7 — CI/CD
Plan: docs/plans/2026-07-09-phase7-cicd.md
CORE DONE (10384bc..c0a841d). GitHub OIDC provider + ztd-capstone-ci role (bootstrap); additive EKS access entry (5 existing untouched); Sonar project ztd-capstone + github-actions token; gh secrets SONAR_TOKEN/SONAR_HOST_URL/AWS_DEPLOY_ROLE_ARN + vars AWS_REGION/ECR_REGISTRY; 4 workflows actionlint-clean.
ci.yml GREEN: build->Trivy(HIGH/CRITICAL gate active+passing after CVE fixes)->push ECR (sha-c0a841d)->cosign sign+SBOM. .trivyignore = unfixable base OS CVEs + 2 breaking-major app deps (justified).
DEFERRED to Phase 8 (ArgoCD): deploy-dev rework (->git tag bump) + live pr-checks/Sonar green run.
NOTE: rotated Sonar admin pw only in session scratchpad (Sonar torn down at end anyway; recreate resets to admin/admin).
Phase 7: CORE COMPLETE.
