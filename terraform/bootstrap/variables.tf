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
