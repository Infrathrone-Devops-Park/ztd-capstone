provider "aws" {
  region = var.region
  # Locally, credentials come from the named CLI profile. In CI (GitHub
  # Actions, e.g. terraform.yml's read-only plan), credentials come from the
  # OIDC-assumed role via aws-actions/configure-aws-credentials (env vars) —
  # no named profile exists there, so CI passes -var aws_profile="" and this
  # becomes null (falls back to the default credential chain: env/OIDC).
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      project    = var.project
      managed-by = "terraform"
      layer      = "bootstrap"
    }
  }
}
