provider "aws" {
  region = var.region
  # Locally, credentials come from the named CLI profile. In CI (GitHub
  # Actions), credentials come from the OIDC-assumed role via
  # aws-actions/configure-aws-credentials (env vars) — no named profile
  # exists there, so CI passes -var aws_profile="" and this becomes null
  # (falls back to the default credential chain: env vars / OIDC).
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      project    = var.project
      managed-by = "terraform"
      layer      = "stack"
    }
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
