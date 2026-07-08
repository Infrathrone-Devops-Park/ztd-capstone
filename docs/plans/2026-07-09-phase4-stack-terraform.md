# Phase 4 — Stack Terraform (Nodegroup + SonarQube EC2 + Namespaces) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the `terraform/stack/` root (S3 backend from bootstrap) that provisions the cost-toggle platform: a dedicated EKS **managed nodegroup** on the existing `ztd-demo` cluster (for observability + app), a **SonarQube EC2** (self-hosted, docker-compose), and the Kubernetes **namespaces**. This phase creates real, billable, additive infra on the shared cluster — with maximum caution so nothing existing is touched. Observability and app Helm releases are added to this same root in Phases 5–6 (so a single `terraform apply` ultimately brings up everything).

**Architecture:** All existing infrastructure (cluster, VPC, subnets, existing nodegroup `ng-dense`, OIDC) is read **only** via `data` sources. New resources are additive and independently destroyable: a new node IAM role + managed nodegroup labeled `workload=platform`, a SonarQube EC2 (public subnet, EIP, SSM Session Manager access — no SSH key) running SonarQube Community + Postgres via docker-compose from user-data, and four namespaces. `terraform destroy` removes exactly these and nothing else.

**Tech Stack:** Terraform ≥1.7, AWS provider ~>5.0, Kubernetes + Helm providers, EKS managed nodegroups, EC2 (Amazon Linux 2023), SSM, docker-compose.

## Global Constraints

_Every task's requirements implicitly include this section._

- **AWS:** profile `infrathrone-new`, account `514422154867`, region `ap-south-1`.
- **⚠️ EXISTING-INFRA PROTECTION (paramount this phase):**
  - The cluster, its VPC, subnets, OIDC provider, and the existing nodegroup **`ng-dense`** are referenced via `data` sources ONLY. NEVER `import`, modify, or destroy them.
  - Do NOT edit the `aws-auth` ConfigMap or existing access entries. EKS **managed** nodegroups handle node authorization automatically — rely on that; touch nothing shared.
  - New security groups are created fresh; NEVER modify the cluster SG (`sg-008d0b46622ba993f`) or any existing SG. (The nodegroup uses the cluster's managed node SG automatically; that's EKS-managed, not us.)
  - Every plan MUST be inspected before apply. Anything showing a change/destroy of a resource we did not create → STOP, do not apply, report.
  - Tag every resource `project=ztd-capstone`, `managed-by=terraform`, `layer=stack`.
- **Known IDs (use as variable DEFAULTS; documented, stable):**
  - VPC `vpc-062ffcaf33a87760f`; cluster `ztd-demo` (1.31); cluster SG `sg-008d0b46622ba993f`.
  - Private subnets (nodegroup): `subnet-092d8bf0bdba1ede3`, `subnet-017f49a267f59869b`, `subnet-09276e71db6d46cc7`.
  - Public subnets (SonarQube): `subnet-0c106bdac632ddf35`, `subnet-08fd75b717c891983`, `subnet-082e7f345a2574ecb`.
  - Operator IP `103.133.30.126/32` (SonarQube UI/admin ingress default).
- **Commits:** `SaiPisey2 <piseysai0202@gmail.com>`. NO Claude attribution.
- **Secrets:** SonarQube DB password stored in an SSM SecureString written by TF from a sensitive var (default generated via `random_password`); never committed. No secret in user-data plaintext beyond what the instance fetches from SSM.
- **You are authorized to `terraform apply` autonomously** (the coordinator has waived per-apply approval), but ONLY after inspecting the plan and confirming it creates/reads the intended resources and shows `0 to destroy` of anything pre-existing.

---

## File Structure

```
terraform/stack/
├── versions.tf              # terraform + providers (aws, kubernetes, helm) version pins
├── backend.tf               # S3 backend → ztd-capstone-tfstate-514422154867, dynamodb lock
├── providers.tf             # aws (profile, default_tags); kubernetes+helm auth via EKS data + token
├── variables.tf             # region, ids, subnet lists, instance sizes, sonar vars, operator cidr
├── data.tf                  # data: aws_eks_cluster, aws_eks_cluster_auth, aws_ssm(AL2023 AMI), aws_caller_identity
├── nodegroup.tf             # node IAM role + policy attachments + aws_eks_node_group
├── sonarqube.tf             # SSM param, IAM role/instance-profile, SG, EC2, EIP
├── templates/
│   └── sonar_userdata.sh.tftpl  # cloud-init: docker, sysctl, docker-compose up sonarqube+postgres
├── namespaces.tf            # kubernetes_namespace dev/staging/prod/observability
├── outputs.tf               # nodegroup name, sonar public ip/url, namespace names
└── terraform.tfvars.example
```

---

### Task 1: Stack backend, providers, variables, data sources

**Files:** `versions.tf`, `backend.tf`, `providers.tf`, `variables.tf`, `data.tf`, `terraform.tfvars.example`.

**Interfaces:**
- Produces configured `aws`, `kubernetes`, `helm` providers; data sources `data.aws_eks_cluster.this`, `data.aws_eks_cluster_auth.this`, `data.aws_ssm_parameter.al2023`, `data.aws_caller_identity.current`; variables consumed by all later tasks.

- [ ] **Step 1: `versions.tf`** — required_version ≥1.7; providers aws ~>5.0, kubernetes ~>2.30, helm ~>2.13.
- [ ] **Step 2: `backend.tf`** — S3 backend: bucket `ztd-capstone-tfstate-514422154867`, key `stack/terraform.tfstate`, region `ap-south-1`, dynamodb_table `ztd-capstone-tflock`, encrypt true. (profile passed via `-backend-config` or AWS_PROFILE env at init.)
- [ ] **Step 3: `variables.tf`** — region, aws_profile, project (default ztd-capstone), account_id, cluster_name (ztd-demo), vpc_id, private_subnet_ids (list, defaults above), public_subnet_ids (list, defaults above), node_instance_type (t3.large), node_desired/min/max (2/2/3), node_disk_gib (30), sonar_instance_type (t3.medium), sonar_disk_gib (30), operator_cidr (103.133.30.126/32), sonar_ingress_cidr (default "0.0.0.0/0" WITH a description warning it exposes :9000; needed so GitHub-hosted Actions runners can reach Sonar — rely on Sonar auth/token), sonar_db_password (sensitive, default "" → generated).
- [ ] **Step 4: `providers.tf`** — aws (region, profile, default_tags project/managed-by/layer=stack). kubernetes + helm providers authenticate to the existing cluster:
  ```hcl
  provider "kubernetes" {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
  provider "helm" { kubernetes { host = ... ca ... token ... } }  # same auth
  ```
- [ ] **Step 5: `data.tf`** — `aws_eks_cluster.this` (name=var.cluster_name), `aws_eks_cluster_auth.this` (name=var.cluster_name), `aws_ssm_parameter.al2023` (`/aws/service/eks/optimized-ami/1.31/amazon-linux-2023/x86_64/standard/recommended/image_id` — the EKS-optimized AL2023 AMI; NOTE: nodegroup uses `ami_type` not a raw AMI, so this data source is only needed if a custom AMI is used — prefer `ami_type = "AL2023_x86_64_STANDARD"` and DROP the AMI data source for the nodegroup; keep a separate `aws_ssm_parameter` for the SonarQube EC2 plain AL2023 AMI `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`), `aws_caller_identity.current`.
- [ ] **Step 6: `terraform.tfvars.example`** — documents the vars (no secrets).
- [ ] **Step 7: init + validate** — `cd terraform/stack && AWS_PROFILE=infrathrone-new terraform init && terraform validate` → success. `terraform plan` at this point should be `0 to add` (only data sources) — confirm it reads the cluster and shows NO resource changes.
- [ ] **Step 8: Commit** — `feat(tf-stack): backend, providers, variables, data sources`.

---

### Task 2: Node IAM role + managed nodegroup

**Files:** `nodegroup.tf`.

**Interfaces:**
- Consumes cluster data + subnet vars.
- Produces `aws_eks_node_group.platform` (label `workload=platform`) and its IAM role. Later phases schedule obs/app pods onto it via `nodeSelector: {workload: platform}`.

- [ ] **Step 1: `nodegroup.tf`** —
  - `aws_iam_role.node` (assume EC2), attach managed policies: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`.
  - `aws_eks_node_group.platform`: cluster_name=var.cluster_name, node_group_name `ztd-capstone-platform`, node_role_arn=role, subnet_ids=var.private_subnet_ids, `ami_type="AL2023_x86_64_STANDARD"`, instance_types=[var.node_instance_type], scaling_config (desired/min/max), disk_size=var.node_disk_gib, labels={workload="platform"}, update_config max_unavailable=1, tags. Add `lifecycle { ignore_changes = [scaling_config[0].desired_size] }` optional.
- [ ] **Step 2: Plan (SAFETY GATE)** — `terraform plan`. Confirm: adds exactly the node role + 4 attachments + 1 node group; `0 to destroy`; NOTHING references or changes `ng-dense`, the cluster, or existing SGs. If plan shows any change to a pre-existing resource, STOP.
- [ ] **Step 3: Apply** — `terraform apply -auto-approve`. Nodegroup creation takes ~3-5 min.
- [ ] **Step 4: Verify nodes join + labeled + ng-dense intact** —
  ```bash
  export AWS_PROFILE=infrathrone-new
  K="kubectl --context arn:aws:eks:ap-south-1:514422154867:cluster/ztd-demo"
  $K get nodes -L workload,node.kubernetes.io/instance-type
  ```
  Expect: the original 2× t3.small (ng-dense, no workload label) STILL present AND 2 new t3.large nodes with `workload=platform`, all Ready. Also `aws eks list-nodegroups --cluster-name ztd-demo` shows `ng-dense` AND `ztd-capstone-platform` (ng-dense unchanged: `aws eks describe-nodegroup --nodegroup-name ng-dense` scaling still 2/2/3, instance t3.small).
- [ ] **Step 5: Commit** — `feat(tf-stack): dedicated platform managed nodegroup`.

---

### Task 3: SonarQube EC2 (docker-compose, SSM access)

**Files:** `sonarqube.tf`, `templates/sonar_userdata.sh.tftpl`.

**Interfaces:**
- Produces a running SonarQube reachable at `http://<eip>:9000`. URL exported for CI (`SONAR_HOST_URL`).

- [ ] **Step 1: `templates/sonar_userdata.sh.tftpl`** — cloud-init bash:
  - `dnf install -y docker`; enable+start docker; install docker compose plugin (`/usr/libexec/docker/cli-plugins/docker-compose` via curl of the release binary for linux x86_64).
  - `sysctl -w vm.max_map_count=524288` and `fs.file-max=131072`; persist to `/etc/sysctl.d/99-sonarqube.conf` (Elasticsearch requirement — SonarQube won't start otherwise).
  - Fetch DB password from SSM: `PW=$(aws ssm get-parameter --with-decryption --name ${ssm_pw_name} --region ${region} --query Parameter.Value --output text)`.
  - Write `/opt/sonar/docker-compose.yml`: service `db` (postgres:16, env POSTGRES_USER=sonar, POSTGRES_PASSWORD=$PW, POSTGRES_DB=sonar, named volume), service `sonarqube` (image `sonarqube:community`, env `SONAR_JDBC_URL=jdbc:postgresql://db:5432/sonar`, `SONAR_JDBC_USERNAME=sonar`, `SONAR_JDBC_PASSWORD=$PW`, ports 9000:9000, ulimits nofile 65536, depends_on db, named volumes for data/extensions/logs), restart unless-stopped.
  - `cd /opt/sonar && docker compose up -d`.
- [ ] **Step 2: `sonarqube.tf`** —
  - `random_password.sonar_db` (length 24, special false) used when var.sonar_db_password == "".
  - `aws_ssm_parameter.sonar_db` (type SecureString, name `/ztd-capstone/sonar/db-password`, value = coalesce(var, random)).
  - `aws_iam_role.sonar` + instance profile; attach `AmazonSSMManagedInstanceCore` (Session Manager) + inline policy allowing `ssm:GetParameter` on the sonar param ARN.
  - `aws_security_group.sonar` in var.vpc_id: ingress 9000 from var.sonar_ingress_cidr; egress all. (NO port 22 — SSM only.)
  - `aws_instance.sonar`: ami=al2023 SSM data, type=var.sonar_instance_type, subnet=element(var.public_subnet_ids,0), vpc_security_group_ids=[sg], iam_instance_profile, associate_public_ip_address=true, root_block_device gp3 var.sonar_disk_gib, user_data=templatefile(...) passing ssm_pw_name+region, tags Name=ztd-capstone-sonarqube.
  - `aws_eip.sonar` associated with the instance.
- [ ] **Step 3: Plan + apply** — inspect plan (adds SSM param, IAM, SG, instance, EIP; `0 to destroy`; no existing-resource changes), then `terraform apply -auto-approve`.
- [ ] **Step 4: Verify Sonar comes up** — poll `curl -s http://<eip>:9000/api/system/status` until `{"status":"UP"...}` (SonarQube takes ~3-5 min to boot ES + migrate DB). Use a bounded retry loop (e.g. up to 15 min). Report the final status JSON. Confirm SSM Session Manager works: `aws ssm start-session` not required, but verify the instance shows in `aws ssm describe-instance-information`.
- [ ] **Step 5: Commit** — `feat(tf-stack): self-hosted SonarQube EC2 via docker-compose and SSM`.

---

### Task 4: Kubernetes namespaces

**Files:** `namespaces.tf`.

**Interfaces:** produces namespaces `dev`, `staging`, `prod`, `observability` (labeled `project=ztd-capstone`, and `kubernetes.io/metadata.name` is automatic — used by the chart's NetworkPolicy ingress-nginx selector).

- [ ] **Step 1: `namespaces.tf`** — `kubernetes_namespace` for each of dev/staging/prod/observability with labels. Use `for_each` over a set.
- [ ] **Step 2: Plan + apply** — inspect (adds 4 namespaces; `0 to destroy`), apply.
- [ ] **Step 3: Verify** — `kubectl get ns` shows the 4 new namespaces AND all 6 pre-existing (default, ingress-nginx, kube-*, local-path-storage) untouched.
- [ ] **Step 4: Commit** — `feat(tf-stack): dev/staging/prod/observability namespaces`.

---

### Task 5: Outputs + full-stack safety verification

**Files:** `outputs.tf`.

- [ ] **Step 1: `outputs.tf`** — `nodegroup_name`, `nodegroup_role_arn`, `sonar_public_ip` (eip), `sonar_url` (`http://<eip>:9000`), `namespaces` (list). Mark nothing sensitive except none needed (password is in SSM, not output).
- [ ] **Step 2: Full plan is clean** — `terraform plan` → `No changes. Your infrastructure matches the configuration.` (everything already applied). Confirms idempotency.
- [ ] **Step 3: Comprehensive existing-infra safety audit** —
  ```bash
  export AWS_PROFILE=infrathrone-new
  # ng-dense unchanged
  aws eks describe-nodegroup --cluster-name ztd-demo --nodegroup-name ng-dense --query 'nodegroup.{type:instanceTypes,scaling:scalingConfig,status:status}'
  # cluster untouched
  kubectl --context arn:aws:eks:ap-south-1:514422154867:cluster/ztd-demo get ns
  # our nodegroup healthy
  aws eks describe-nodegroup --cluster-name ztd-demo --nodegroup-name ztd-capstone-platform --query 'nodegroup.status'
  ```
  Expect ng-dense identical to baseline; both nodegroups ACTIVE; original namespaces intact.
- [ ] **Step 4: Commit + push** — `feat(tf-stack): outputs and stack verification`. Push all Phase 4 commits to origin main.

---

## Self-Review

- **Spec coverage:** Implements spec §5.2 (stack layer: nodegroup + SonarQube EC2 + namespaces via kubernetes/helm providers, S3 backend from bootstrap). Nodegroup label `workload=platform` matches the Phase 3 chart nodeSelector. SonarQube URL feeds Phase 6 CI. Observability + app Helm releases are deferred to Phases 5–6 in this same root (single-apply preserved).
- **Placeholder scan:** none — concrete resources, known IDs as documented defaults, explicit verification commands.
- **Interface consistency:** namespaces dev/staging/prod/observability match the chart's target namespaces; nodeSelector label matches; SSM param name consistent between userdata template and `sonarqube.tf`.
- **Safety:** every apply gated by a plan inspection asserting no changes to `ng-dense`/cluster/existing SGs; Task 5 audits ng-dense + namespaces post-apply. Managed nodegroup avoids aws-auth edits.

## Phase Exit Criteria

- `terraform/stack` applied: new `ztd-capstone-platform` nodegroup (2× t3.large, `workload=platform`, Ready), SonarQube reachable at `http://<eip>:9000` (status UP), 4 namespaces created.
- `ng-dense`, the cluster, existing SGs, and original namespaces verified **unchanged**.
- `terraform plan` clean (idempotent). Commits authored SaiPisey2, no Claude attribution, pushed.
- Ready for Phase 5 (observability Helm releases into `observability` ns on the new nodegroup).
