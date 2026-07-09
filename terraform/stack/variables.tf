variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "infrathrone-new"
}

variable "project" {
  description = "Project tag/name prefix"
  type        = string
  default     = "ztd-capstone"
}

variable "account_id" {
  description = "AWS account id (used for tfstate bucket naming consistency)"
  type        = string
  default     = "514422154867"
}

variable "cluster_name" {
  description = "Existing shared EKS cluster name (data source only, never modified)"
  type        = string
  default     = "ztd-demo"
}

variable "vpc_id" {
  description = "Existing shared VPC id (data source only, never modified)"
  type        = string
  default     = "vpc-062ffcaf33a87760f"
}

variable "private_subnet_ids" {
  description = "Private subnet ids used for the new platform nodegroup"
  type        = list(string)
  default = [
    "subnet-092d8bf0bdba1ede3",
    "subnet-017f49a267f59869b",
    "subnet-09276e71db6d46cc7",
  ]
}

variable "public_subnet_ids" {
  description = "Public subnet ids used for the SonarQube EC2 instance"
  type        = list(string)
  default = [
    "subnet-0c106bdac632ddf35",
    "subnet-08fd75b717c891983",
    "subnet-082e7f345a2574ecb",
  ]
}

variable "node_instance_type" {
  description = "Instance type for the dedicated platform nodegroup"
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired node count for the platform nodegroup"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count for the platform nodegroup"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count for the platform nodegroup"
  type        = number
  default     = 3
}

variable "node_disk_gib" {
  description = "Root disk size (GiB) for platform nodegroup nodes"
  type        = number
  default     = 30
}

variable "sonar_instance_type" {
  description = "Instance type for the SonarQube EC2 host"
  type        = string
  default     = "t3.medium"
}

variable "sonar_disk_gib" {
  description = "Root disk size (GiB) for the SonarQube EC2 host"
  type        = number
  default     = 30
}

variable "sonar_ingress_cidr" {
  description = <<-EOT
    CIDR allowed to reach SonarQube on :9000. Defaults to 0.0.0.0/0 so that
    GitHub-hosted Actions runners (which use ephemeral, unpredictable public
    IPs) can reach the Sonar server for CI scans. This intentionally exposes
    the SonarQube web UI/API to the public internet on port 9000 — access
    control relies on SonarQube's own authentication and CI token, not
    network restriction. Narrow this to specific CIDRs (e.g. your office IP)
    if public exposure is not acceptable for your environment.
    EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "sonar_db_password" {
  description = "SonarQube Postgres password. Leave empty to auto-generate via random_password (recommended)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_image_tag" {
  description = "Immutable image tag (e.g. sha-<7hex>) shared by all four ztd-capstone service images in ECR. Set via -var app_image_tag=sha-<gitsha>."
  type        = string
  default     = "sha-38e32ab"
}

variable "app_deploy_enabled" {
  description = "Toggle for deploying the ztd-capstone app helm_release into dev."
  type        = bool
  default     = true
}
