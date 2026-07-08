provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      project    = var.project
      managed-by = "terraform"
      layer      = "bootstrap"
    }
  }
}
