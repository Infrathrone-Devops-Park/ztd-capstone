# All existing shared infra (cluster, VPC, subnets, OIDC, existing nodegroup)
# is referenced via data sources ONLY. Never import/modify/destroy these.

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

# Plain Amazon Linux 2023 AMI for the self-managed SonarQube EC2 instance.
# (The EKS nodegroup uses ami_type = AL2023_x86_64_STANDARD directly and does
# not need a raw AMI id, so no EKS-optimized AMI data source is required.)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
