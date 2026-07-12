# GitHub Actions OIDC → AWS IAM, so CI/CD authenticates without any static
# AWS access keys. This is a persistent (bootstrap-layer) resource: it must
# survive a `terraform/stack` destroy/recreate cycle so CI keeps working
# across full-stack rebuilds.
#
# Existing-infra protection: as of writing, `aws iam list-open-id-connect-providers`
# shows only the two EKS cluster OIDC providers — no
# `token.actions.githubusercontent.com` provider exists yet in this account,
# so it is created here. If one is ever created out-of-band in the future,
# switch this to a `data "aws_iam_openid_connect_provider"` lookup instead of
# re-creating it.

locals {
  github_org_repo = "Infrathrone-Devops-Park/ztd-capstone"

  # Thumbprint of the root CA (ISRG Root X1) that ultimately signs GitHub's
  # OIDC token-issuer TLS certificate (token.actions.githubusercontent.com),
  # per GitHub's documented OIDC signing-certificate rotation
  # (github.blog "GitHub Actions: Updates to OIDC token signing certificate").
  # AWS no longer actually validates this value for this provider, but the
  # Terraform resource still requires a non-empty thumbprint_list.
  github_oidc_thumbprint = "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
}

# The GitHub Actions OIDC provider is ACCOUNT-WIDE — there can be exactly one
# `token.actions.githubusercontent.com` provider per AWS account, and it is
# shared by every repo in the account. So we treat it like other shared infra:
# adopt the existing one via a data source by default, and only CREATE it on a
# fresh account (set -var create_github_oidc_provider=true). This makes
# `terraform apply` idempotent across destroy/recreate cycles instead of failing
# with EntityAlreadyExists when the provider already exists.
resource "aws_iam_openid_connect_provider" "github_actions" {
  count           = var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [local.github_oidc_thumbprint]

  tags = {
    project    = var.project
    managed-by = "terraform"
    layer      = "bootstrap"
  }
}

data "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : data.aws_iam_openid_connect_provider.github_actions[0].arn
}

# ---------------------------------------------------------------------------
# CI role — assumed by GitHub Actions via OIDC, scoped to this repo only.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_org_repo}:*"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.project}-ci"
  assume_role_policy = data.aws_iam_policy_document.ci_assume_role.json

  tags = {
    project    = var.project
    managed-by = "terraform"
    layer      = "bootstrap"
  }
}

# ECR: auth token (account-wide, required action) + push/pull scoped to the
# 4 ztd-capstone/* repositories only.
data "aws_iam_policy_document" "ci_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [for k, v in aws_ecr_repository.service : v.arn]
  }
}

# Terraform remote state: read/write the state object + lock table, so CI can
# run `terraform apply` against terraform/stack.
data "aws_iam_policy_document" "ci_tfstate" {
  statement {
    sid       = "TfStateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "TfStateObjectRW"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    sid       = "TfLockTable"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.tflock.arn]
  }
}

# EKS: describe the shared cluster (needed by the kubernetes/helm providers'
# data sources when CI runs `terraform apply` in terraform/stack). The
# corresponding data-plane access (aws-auth / access entry) is granted
# additively in terraform/stack/ci_access.tf — never here.
data "aws_iam_policy_document" "ci_eks" {
  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:${var.account_id}:cluster/ztd-demo"]
  }
}

resource "aws_iam_role_policy" "ci_ecr" {
  name   = "${var.project}-ci-ecr"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_ecr.json
}

resource "aws_iam_role_policy" "ci_tfstate" {
  name   = "${var.project}-ci-tfstate"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_tfstate.json
}

resource "aws_iam_role_policy" "ci_eks" {
  name   = "${var.project}-ci-eks"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_eks.json
}
