variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
  default     = "infrathrone-new"
}

variable "account_id" {
  description = "AWS account id (used to make S3 bucket name globally unique)"
  type        = string
  default     = "514422154867"
}

variable "project" {
  description = "Project tag / name prefix"
  type        = string
  default     = "ztd-capstone"
}

variable "ecr_repositories" {
  description = "Service names to create ECR repos for"
  type        = list(string)
  default     = ["frontend", "api-gateway", "orders", "catalog"]
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Whether to CREATE the account-wide GitHub Actions OIDC provider
    (token.actions.githubusercontent.com). There can be only one per AWS
    account. Default false = adopt the existing provider via a data source
    (correct when it already exists, e.g. this account). Set true only on a
    fresh account that has no such provider yet.
  EOT
  type        = bool
  default     = false
}
