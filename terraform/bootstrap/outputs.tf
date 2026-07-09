output "state_bucket" {
  description = "S3 bucket holding stack-layer remote state"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  description = "DynamoDB table for state locking"
  value       = aws_dynamodb_table.tflock.name
}

output "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL"
  value       = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}

output "ci_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (no static AWS keys)"
  value       = aws_iam_role.ci.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
