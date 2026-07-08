resource "aws_ecr_repository" "service" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  # force_delete allows a clean full teardown even when images are present
  # (the whole capstone is torn down for recreate-from-zero verification).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 15 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}
