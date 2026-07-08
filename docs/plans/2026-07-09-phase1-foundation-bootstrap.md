# Phase 1 — Foundation & Bootstrap Terraform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the monorepo and create the persistent Terraform "bootstrap" layer — S3 remote-state bucket, DynamoDB lock table, and ECR repositories — as 100% greenfield resources that never touch existing infrastructure.

**Architecture:** Two Terraform roots. This phase builds `terraform/bootstrap/` with **local state**, creating only brand-new AWS resources. A later phase's `terraform/stack/` will use the S3 bucket created here as its backend. No data sources reading existing infra in this phase.

**Tech Stack:** Terraform ≥ 1.7, AWS provider ~> 5.0, AWS CLI v2, git.

## Global Constraints

_Every task's requirements implicitly include this section. Copied from the spec._

- **AWS profile:** `infrathrone-new`. **Account:** `514422154867`. **Region:** `ap-south-1`.
- **⚠️ EXISTING-INFRA PROTECTION (applies to ALL phases):**
  - Terraform must **never** `import`, manage, or mutate any pre-existing resource: the `ztd-demo` cluster, its default nodegroup, `ingress-nginx`, the VPC, existing subnets, or existing security groups. Existing infra is referenced **read-only via `data` sources only** (not in this phase — this phase reads nothing existing).
  - Kubernetes deploys (later phases) go only into **new namespaces** (`dev`, `staging`, `prod`, `observability`). Never `default`, `kube-system`, `ingress-nginx`, `local-path-storage`.
  - Every AWS resource carries tags `project = "ztd-capstone"` and `managed-by = "terraform"` for identification and scoped teardown.
- **Commits:** authored as `SaiPisey2 <piseysai0202@gmail.com>`. **No Claude attribution** in any commit message, file header, or PR. Use `git -c user.name=... -c user.email=... commit` with no `Co-Authored-By` trailer.
- **Naming:** all resources prefixed `ztd-capstone`. Globally-unique names suffixed with account id `514422154867`.
- **Bootstrap layer is persistent:** it is created once and NOT part of the `apply`/`destroy` cost toggle. Do not run `terraform destroy` on `bootstrap/` during normal operation.

---

## File Structure

```
ztd-capstone/
├── .gitignore                              # NEW — ignore secrets, tfstate, local files
├── README.md                               # NEW — project overview + operator workflow
├── services/{frontend,api-gateway,orders,catalog}/.gitkeep   # NEW — placeholders
├── deploy/{helm,observability}/.gitkeep    # NEW — placeholders
└── terraform/
    └── bootstrap/
        ├── versions.tf                     # NEW — terraform + provider version pins
        ├── providers.tf                    # NEW — aws provider (profile, region, default tags)
        ├── variables.tf                    # NEW — region, profile, project, ecr repo list
        ├── s3_state.tf                     # NEW — state bucket + versioning + encryption + public block
        ├── dynamodb_lock.tf                # NEW — state lock table
        ├── ecr.tf                          # NEW — 4 ECR repos + lifecycle policy
        ├── outputs.tf                       # NEW — bucket name, table name, repo URLs
        └── terraform.tfvars.example        # NEW — example var values (committed; real tfvars gitignored)
```

**Responsibilities:** each `.tf` file owns exactly one resource group so a reviewer can accept/reject independently. `bootstrap/` produces working, verifiable infra on its own (a usable backend + registries) — the phase deliverable.

---

### Task 1: Repo scaffold — .gitignore, README, directory placeholders

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `services/frontend/.gitkeep`, `services/api-gateway/.gitkeep`, `services/orders/.gitkeep`, `services/catalog/.gitkeep`
- Create: `deploy/helm/.gitkeep`, `deploy/observability/.gitkeep`

**Interfaces:**
- Produces: repo directory skeleton later phases populate; `.gitignore` rules that keep secrets/state out of git.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# secrets & env
.env
.env.*
!.env.example
*.pem
*.key

# terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
override.tf
override.tf.json

# kube
kubeconfig
*.kubeconfig

# node / python / go build junk
node_modules/
dist/
__pycache__/
*.pyc
.venv/
bin/

# os / editor
.DS_Store
.idea/
.vscode/
```

- [ ] **Step 2: Create directory placeholders**

Run:
```bash
mkdir -p services/frontend services/api-gateway services/orders services/catalog deploy/helm deploy/observability
touch services/frontend/.gitkeep services/api-gateway/.gitkeep services/orders/.gitkeep services/catalog/.gitkeep deploy/helm/.gitkeep deploy/observability/.gitkeep
```

- [ ] **Step 3: Create `README.md`**

```markdown
# ztd-capstone

Production-grade DevOps capstone: polyglot e-commerce microservices with GitHub Actions CI/CD, SonarQube + Trivy gates, Terraform IaC, Kubernetes deployment to EKS, and a full observability stack (Prometheus, Grafana, Loki, Promtail, Tempo, OpenTelemetry).

See [`docs/specs/2026-07-09-ztd-capstone-design.md`](docs/specs/2026-07-09-ztd-capstone-design.md) for the design.

## Layout
- `services/` — the microservices (frontend, api-gateway, orders, catalog)
- `deploy/` — Helm charts and observability config
- `terraform/bootstrap/` — persistent state bucket + lock table + ECR (run once)
- `terraform/stack/` — the cost toggle: nodegroup + SonarQube EC2 + observability + app
- `.github/workflows/` — CI/CD pipelines

## Operator workflow
```bash
# one-time
cd terraform/bootstrap && terraform init && terraform apply

# cost toggle
cd terraform/stack && terraform apply    # platform UP
cd terraform/stack && terraform destroy  # platform DOWN (shared cluster untouched)
```

## Safety
Terraform never manages the shared `ztd-demo` cluster, its default nodegroup, or `ingress-nginx`. Existing infra is read-only. Deploys land only in dedicated namespaces.
```

- [ ] **Step 4: Verify tree**

Run: `find services deploy -type f; cat .gitignore | head -3`
Expected: 6 `.gitkeep` files listed; `.gitignore` starts with the secrets block.

- [ ] **Step 5: Commit**

```bash
git add .gitignore README.md services deploy
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "chore: scaffold monorepo structure and gitignore"
```

---

### Task 2: Bootstrap Terraform — versions, providers, variables

**Files:**
- Create: `terraform/bootstrap/versions.tf`
- Create: `terraform/bootstrap/providers.tf`
- Create: `terraform/bootstrap/variables.tf`
- Create: `terraform/bootstrap/terraform.tfvars.example`

**Interfaces:**
- Produces: `var.region`, `var.aws_profile`, `var.project`, `var.account_id`, `var.ecr_repositories` (list(string)) consumed by later bootstrap tasks; AWS provider with default tags `project`/`managed-by`.

- [ ] **Step 1: Create `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- [ ] **Step 2: Create `variables.tf`**

```hcl
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
```

- [ ] **Step 3: Create `providers.tf`**

```hcl
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
```

- [ ] **Step 4: Create `terraform.tfvars.example`**

```hcl
# Copy to terraform.tfvars (gitignored) and adjust if needed.
region      = "ap-south-1"
aws_profile = "infrathrone-new"
account_id  = "514422154867"
project     = "ztd-capstone"
```

- [ ] **Step 5: Init + validate (expect success, no resources yet)**

Run:
```bash
cd terraform/bootstrap && terraform init && terraform validate
```
Expected: `Terraform has been successfully initialized!` then `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add terraform/bootstrap/versions.tf terraform/bootstrap/providers.tf terraform/bootstrap/variables.tf terraform/bootstrap/terraform.tfvars.example
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "feat(tf): bootstrap providers, versions, variables"
```

---

### Task 3: Bootstrap Terraform — S3 remote-state bucket

**Files:**
- Create: `terraform/bootstrap/s3_state.tf`

**Interfaces:**
- Consumes: `var.project`, `var.account_id`.
- Produces: S3 bucket `${var.project}-tfstate-${var.account_id}` (versioned, SSE-encrypted, public access blocked) — the backend target for `terraform/stack/` in a later phase.

- [ ] **Step 1: Create `s3_state.tf`**

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${var.account_id}"

  # Persistent layer — guard against accidental deletion of the state bucket.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **Step 2: Validate + plan (assert only NEW resources)**

Run:
```bash
cd terraform/bootstrap && terraform validate && terraform plan -no-color | tail -20
```
Expected: `Success!` and a plan showing `4 to add, 0 to change, 0 to destroy` (bucket + versioning + encryption + public-access-block). **Verify `0 to destroy`** — no existing resource touched.

- [ ] **Step 3: Commit**

```bash
git add terraform/bootstrap/s3_state.tf
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "feat(tf): S3 remote state bucket for bootstrap"
```

---

### Task 4: Bootstrap Terraform — DynamoDB state-lock table

**Files:**
- Create: `terraform/bootstrap/dynamodb_lock.tf`

**Interfaces:**
- Consumes: `var.project`.
- Produces: DynamoDB table `${var.project}-tflock` with `LockID` hash key — the lock table for `terraform/stack/`.

- [ ] **Step 1: Create `dynamodb_lock.tf`**

```hcl
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

- [ ] **Step 2: Validate + plan**

Run: `cd terraform/bootstrap && terraform validate && terraform plan -no-color | tail -20`
Expected: `Success!`; plan now shows `5 to add, 0 to change, 0 to destroy`.

- [ ] **Step 3: Commit**

```bash
git add terraform/bootstrap/dynamodb_lock.tf
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "feat(tf): DynamoDB lock table for bootstrap"
```

---

### Task 5: Bootstrap Terraform — ECR repositories

**Files:**
- Create: `terraform/bootstrap/ecr.tf`

**Interfaces:**
- Consumes: `var.project`, `var.ecr_repositories`.
- Produces: 4 ECR repos named `${var.project}/${name}` with scan-on-push + a lifecycle policy keeping the last 15 images. Repo URLs exposed in outputs (Task 6).

- [ ] **Step 1: Create `ecr.tf`**

```hcl
resource "aws_ecr_repository" "service" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

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
```

- [ ] **Step 2: Validate + plan**

Run: `cd terraform/bootstrap && terraform validate && terraform plan -no-color | tail -30`
Expected: `Success!`; plan shows `13 to add, 0 to change, 0 to destroy` (5 prior + 4 repos + 4 lifecycle policies). **Confirm `0 to destroy`.**

- [ ] **Step 3: Commit**

```bash
git add terraform/bootstrap/ecr.tf
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "feat(tf): ECR repositories with scan-on-push and lifecycle"
```

---

### Task 6: Outputs, apply, and verification

**Files:**
- Create: `terraform/bootstrap/outputs.tf`

**Interfaces:**
- Consumes: all prior bootstrap resources.
- Produces: outputs `state_bucket`, `lock_table`, `ecr_repository_urls` (map) — consumed by the operator and by `terraform/stack/` backend config in a later phase.

- [ ] **Step 1: Create `outputs.tf`**

```hcl
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
```

- [ ] **Step 2: Final plan review (safety gate)**

Run: `cd terraform/bootstrap && terraform plan -no-color | tail -40`
Expected: `13 to add, 0 to change, 0 to destroy`. **STOP and do not apply if the plan shows anything to change or destroy** — that would mean it is touching pre-existing state.

- [ ] **Step 3: Apply**

Run: `cd terraform/bootstrap && terraform apply -auto-approve`
Expected: `Apply complete! Resources: 13 added, 0 changed, 0 destroyed.` and the three outputs printed.

- [ ] **Step 4: Verify resources exist via AWS CLI (independent of Terraform state)**

Run:
```bash
export AWS_PROFILE=infrathrone-new
aws s3api head-bucket --bucket ztd-capstone-tfstate-514422154867 && echo "BUCKET_OK"
aws dynamodb describe-table --table-name ztd-capstone-tflock --query 'Table.TableStatus' --output text
aws ecr describe-repositories --query 'repositories[?starts_with(repositoryName, `ztd-capstone/`)].repositoryName' --output text
```
Expected: `BUCKET_OK`; `ACTIVE`; and the four repo names `ztd-capstone/frontend ztd-capstone/api-gateway ztd-capstone/orders ztd-capstone/catalog`.

- [ ] **Step 5: Confirm no existing infra was affected**

Run:
```bash
export AWS_PROFILE=infrathrone-new
kubectl --context arn:aws:eks:ap-south-1:514422154867:cluster/ztd-demo get ns
kubectl --context arn:aws:eks:ap-south-1:514422154867:cluster/ztd-demo get nodes
```
Expected: identical to the pre-phase baseline — same namespaces (default, ingress-nginx, kube-*, local-path-storage), same 2× t3.small nodes. Bootstrap created only AWS S3/DynamoDB/ECR — the cluster is unchanged by design.

- [ ] **Step 6: Commit outputs**

```bash
git add terraform/bootstrap/outputs.tf
git -c user.name="SaiPisey2" -c user.email="piseysai0202@gmail.com" commit -m "feat(tf): bootstrap outputs (state bucket, lock table, ecr urls)"
```

- [ ] **Step 7: Push branch**

```bash
git push -u origin main
```
Expected: push succeeds to `github.com:Infrathrone-Devops-Park/ztd-capstone`. Verify on GitHub the commit author shows **SaiPisey2** and no Claude attribution appears.

---

## Self-Review

- **Spec coverage:** Covers spec §4 repo layout (scaffold), §5.1 bootstrap layer (S3 + DynamoDB + ECR), §10 phase 1. ECR immutability + scan-on-push satisfies §8 supply chain. Remaining spec sections are later phases (2–8) — intentionally out of this plan.
- **Placeholder scan:** none — every step has concrete HCL/commands/expected output.
- **Type consistency:** `var.project`, `var.account_id`, `var.ecr_repositories` used consistently across Tasks 2–6; output names match resource references.
- **Safety:** every `plan`/`apply` step asserts `0 to destroy`; Step 5 of Task 6 confirms the cluster baseline is untouched. Bootstrap reads no existing infra.

## Phase Exit Criteria

- `terraform/bootstrap` applied: S3 bucket, DynamoDB table, 4 ECR repos exist and verified via AWS CLI.
- Cluster namespaces + nodes unchanged from baseline.
- All commits authored as SaiPisey2, pushed to `main`, no Claude attribution.
- Next phase (Phase 2 — app services) can begin; `terraform/stack/` backend will point at the bucket created here.
