# Phase 8: ArgoCD (GitOps CD). Installs into the `argocd` namespace
# (kubernetes_namespace.this["argocd"], namespaces.tf) on the dedicated
# platform nodegroup only (deploy/argocd/argocd-values.yaml sets
# global.nodeSelector = {workload: platform} for every component) — nothing
# lands on the shared ng-dense nodegroup or touches any other namespace.
#
# Repo is public, so no git credentials/repo Secret are configured — the
# Application manifests (deploy/argocd/*) reference the repo over anonymous
# HTTPS.

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.1.2"
  namespace  = kubernetes_namespace.this["argocd"].metadata[0].name
  timeout    = 900

  values = [file("${path.module}/../../deploy/argocd/argocd-values.yaml")]
}

# ---------------------------------------------------------------------------
# Root "app-of-apps" Application: registered once via Terraform so that a
# `terraform apply` bootstraps the whole GitOps tree. It points at
# deploy/argocd/apps/ (recursive dir source) and ArgoCD itself creates the
# per-env dev/staging/prod child Applications found there — Terraform never
# manages those directly.
#
# Applied with `kubectl` (not the kubernetes_manifest resource) because the
# Application CRD is installed by helm_release.argocd in this same apply —
# kubernetes_manifest validates against the live API-server schema at plan
# time, which would fail on a from-scratch bootstrap before the CRD exists.
# A null_resource + local-exec sidesteps that chicken-and-egg problem while
# keeping the whole stack (platform + ArgoCD + root app) a single
# `terraform apply`. The trigger is the manifest's content hash, so re-plans
# are no-ops unless deploy/argocd/root-app.yaml actually changes (or the
# release is replaced) — `terraform plan` stays idempotent.
resource "null_resource" "argocd_root_app" {
  triggers = {
    manifest_sha256 = filesha256("${path.module}/../../deploy/argocd/root-app.yaml")
    argocd_release  = helm_release.argocd.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KCFG="$(mktemp)"
      trap 'rm -f "$KCFG"' EXIT
      aws eks update-kubeconfig \
        --name "${var.cluster_name}" \
        --region "${var.region}" \
        ${var.aws_profile != "" ? "--profile ${var.aws_profile}" : ""} \
        --kubeconfig "$KCFG" >/dev/null
      kubectl --kubeconfig "$KCFG" apply -f "${path.module}/../../deploy/argocd/root-app.yaml"
    EOT
  }

  depends_on = [helm_release.argocd]
}
