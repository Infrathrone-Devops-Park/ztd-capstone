# Additive EKS access entry for the CI role (created in
# terraform/bootstrap/github_oidc.tf) so GitHub Actions can run
# `terraform apply` (helm/kubernetes providers) against the `dev` namespace
# to roll a new app_image_tag. This is the ONLY access-entry change made
# here — no pre-existing access entry (AWSServiceRoleForAmazonEKS,
# ng-dense/ng-small node roles, the platform node role, or the Admin user)
# is touched or modified.
#
# The CI role itself is data-sourced (it lives in the bootstrap layer, which
# uses local state — no remote-state coupling needed, a lookup by name is
# sufficient and keeps the two layers independent).

data "aws_iam_role" "ci" {
  name = "${var.project}-ci"
}

resource "aws_eks_access_entry" "ci" {
  cluster_name  = var.cluster_name
  principal_arn = data.aws_iam_role.ci.arn
  type          = "STANDARD"

  tags = {
    project    = var.project
    managed-by = "terraform"
    layer      = "stack"
  }
}

# Scoped to the `dev` namespace only — enough for CI to roll the app chart's
# image tag (Deployments/Services/Secrets/etc. in `dev`), nothing
# cluster-wide.
resource "aws_eks_access_policy_association" "ci_dev_edit" {
  cluster_name  = var.cluster_name
  principal_arn = data.aws_iam_role.ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["dev"]
  }
}
