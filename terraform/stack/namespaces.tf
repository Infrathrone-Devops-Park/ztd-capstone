# App/observability namespaces on the shared cluster. Purely additive;
# does not touch any pre-existing namespace (default, ingress-nginx,
# kube-system, kube-public, kube-node-lease, local-path-storage).

locals {
  namespace_names = toset(["dev", "staging", "prod", "observability"])
}

resource "kubernetes_namespace" "this" {
  for_each = local.namespace_names

  metadata {
    name = each.value

    labels = {
      project = var.project
    }
  }
}
