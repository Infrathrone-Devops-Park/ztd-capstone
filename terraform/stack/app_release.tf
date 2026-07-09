# Staging / prod promotion targets for release.yml (Phase 7 Task 4). Mirrors
# app.tf's dev helm_release.app pattern but gated behind count so that a
# plain `terraform apply` (no -var overrides) is a strict no-op — these
# resources only get created/updated when release.yml explicitly passes
# `-var deploy_staging=true -var staging_image_tag=sha-<gitsha>` (or the prod
# equivalent, gated further by the GitHub `production` Environment's manual
# approval before that job even runs).

resource "random_password" "postgres_staging" {
  count   = var.deploy_staging ? 1 : 0
  length  = 20
  special = false
}

resource "kubernetes_secret" "postgres_staging" {
  count = var.deploy_staging ? 1 : 0

  metadata {
    name      = "ztd-capstone-postgres"
    namespace = kubernetes_namespace.this["staging"].metadata[0].name
  }

  data = {
    postgres-password = random_password.postgres_staging[0].result
    database-url      = "postgresql://ztd:${random_password.postgres_staging[0].result}@postgres:5432/ztd"
  }

  type = "Opaque"
}

resource "helm_release" "app_staging" {
  count = var.deploy_staging ? 1 : 0

  name      = "ztd-capstone"
  chart     = "${path.module}/../../deploy/helm/ztd-capstone"
  namespace = kubernetes_namespace.this["staging"].metadata[0].name
  timeout   = 600

  values = [
    file("${path.module}/../../deploy/helm/ztd-capstone/values.yaml"),
    file("${path.module}/../../deploy/helm/ztd-capstone/values-staging.yaml"),
  ]

  set {
    name  = "image.tag"
    value = var.staging_image_tag
  }

  depends_on = [
    kubernetes_secret.postgres_staging,
    helm_release.kube_prometheus_stack,
  ]
}

resource "random_password" "postgres_prod" {
  count   = var.deploy_prod ? 1 : 0
  length  = 20
  special = false
}

resource "kubernetes_secret" "postgres_prod" {
  count = var.deploy_prod ? 1 : 0

  metadata {
    name      = "ztd-capstone-postgres"
    namespace = kubernetes_namespace.this["prod"].metadata[0].name
  }

  data = {
    postgres-password = random_password.postgres_prod[0].result
    database-url      = "postgresql://ztd:${random_password.postgres_prod[0].result}@postgres:5432/ztd"
  }

  type = "Opaque"
}

resource "helm_release" "app_prod" {
  count = var.deploy_prod ? 1 : 0

  name      = "ztd-capstone"
  chart     = "${path.module}/../../deploy/helm/ztd-capstone"
  namespace = kubernetes_namespace.this["prod"].metadata[0].name
  timeout   = 600

  values = [
    file("${path.module}/../../deploy/helm/ztd-capstone/values.yaml"),
    file("${path.module}/../../deploy/helm/ztd-capstone/values-prod.yaml"),
  ]

  set {
    name  = "image.tag"
    value = var.prod_image_tag
  }

  depends_on = [
    kubernetes_secret.postgres_prod,
    helm_release.kube_prometheus_stack,
  ]
}
