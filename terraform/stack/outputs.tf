output "nodegroup_name" {
  description = "Name of the dedicated platform managed nodegroup"
  value       = aws_eks_node_group.platform.node_group_name
}

output "nodegroup_role_arn" {
  description = "IAM role ARN of the platform nodegroup"
  value       = aws_iam_role.node.arn
}

output "sonar_public_ip" {
  description = "Public (Elastic) IP of the SonarQube server"
  value       = aws_eip.sonar.public_ip
}

output "sonar_url" {
  description = "SonarQube base URL (SONAR_HOST_URL for CI)"
  value       = "http://${aws_eip.sonar.public_ip}:9000"
}

output "namespaces" {
  description = "Namespaces created by the stack layer"
  value       = sort([for ns in kubernetes_namespace.this : ns.metadata[0].name])
}
