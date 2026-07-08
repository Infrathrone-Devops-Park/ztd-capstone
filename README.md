# ztd-capstone

Production-grade DevOps capstone: polyglot e-commerce microservices with GitHub Actions CI/CD, SonarQube + Trivy gates, Terraform IaC, Kubernetes deployment to EKS, and a full observability stack (Prometheus, Grafana, Loki, Promtail, Tempo, OpenTelemetry).

See [`docs/specs/2026-07-09-ztd-capstone-design.md`](docs/specs/2026-07-09-ztd-capstone-design.md) for the design.

## Layout
- `services/` — the microservices (frontend, api-gateway, orders, catalog)
- `deploy/` — Helm charts and observability config
- `terraform/bootstrap/` — persistent state bucket + lock table + ECR (run once)
- `terraform/stack/` — the cost toggle: nodegroup + SonarQube EC2 + observability + app
- `.github/workflows/` — CI/CD pipelines

## Operator workflow
```bash
# one-time
cd terraform/bootstrap && terraform init && terraform apply

# cost toggle
cd terraform/stack && terraform apply    # platform UP
cd terraform/stack && terraform destroy  # platform DOWN (shared cluster untouched)
```

## Safety
Terraform never manages the shared `ztd-demo` cluster, its default nodegroup, or `ingress-nginx`. Existing infra is read-only. Deploys land only in dedicated namespaces.
