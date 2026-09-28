# Three-Tier DevSecOps Application on AWS EKS

![AWS](https://img.shields.io/badge/AWS-EKS%20%7C%20EC2%20%7C%20ECR%20%7C%20S3-orange)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC)
![Jenkins](https://img.shields.io/badge/CI-Jenkins-D24939)
![ArgoCD](https://img.shields.io/badge/CD-ArgoCD%20(GitOps)-EF7B4D)
![Security](https://img.shields.io/badge/DevSecOps-SonarQube%20%7C%20OWASP%20%7C%20Trivy-2E8B57)
![Monitoring](https://img.shields.io/badge/Monitoring-Prometheus%20%7C%20Grafana-E6522C)

End-to-end DevSecOps deployment of a three-tier notes application (React frontend, Node.js API, PostgreSQL) on Amazon EKS:
Jenkins CI with security scanning, images pushed to Amazon ECR, GitOps delivery with ArgoCD, and cluster monitoring with Prometheus and Grafana.

This is a hands-on learning project based on the
[CodeWithMuh three-tier DevSecOps tutorial](https://github.com/codewithmuh/three-tier-devsecops-project),
updated to work in 2026 and redesigned to run for **about $2–5 in total** on AWS. All changes to the original are listed in [`CHANGES.md`](CHANGES.md).

## Architecture

```
Developer ── git push ──► GitHub (this repo = source of truth)
                             │
                             ▼
                 Jenkins on EC2 (provisioned by Terraform)
     SonarQube ─ OWASP Dependency-Check ─ Trivy ─ Docker build
                             │
             push image ──► Amazon ECR
             commit new image tag ──► kubernetes-manifests/
                             │
                             ▼
               ArgoCD (watches kubernetes-manifests/)
                             │
                             ▼
     Amazon EKS ── namespace three-tier ───────────────────────
       ALB Ingress ──  /     ──► frontend (React)
                   └─  /api  ──► backend (Node.js) ──► PostgreSQL
     Prometheus + Grafana (namespace monitoring)
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `app-code/` | Application source: React frontend and Node.js backend |
| `jenkins-server-terraform/` | Terraform for the Jenkins server (VPC, EC2, IAM role, bootstrap script) |
| `jenkins-pipeline/` | Jenkinsfiles for the backend and frontend pipelines |
| `kubernetes-manifests/` | Kubernetes objects: database, backend, frontend, ingress |
| `argocd/` | Declarative ArgoCD Applications (auto-sync) |
| `eks-cluster.yaml` | EKS cluster definition for `eksctl` (Spot nodes, no NAT Gateway) |
| `configure.sh` | Replaces every `__PLACEHOLDER__` with account-specific values |
| `CHANGES.md` | Fixes and cost optimizations compared to the original tutorial |

## Cost strategy

AWS bills by the hour, and the EKS control plane is the most expensive piece. The project is therefore split so that the cluster only exists for a few hours:

| Phase | What runs on AWS | Estimated cost |
| --- | --- | --- |
| Phase 0 — local preparation | Nothing (S3 state bucket only) | ~$0 |
| Session 1 — CI | Jenkins EC2 only | ~$0.30 |
| Session 2 — CD & monitoring | Jenkins + EKS + 1 ALB, destroyed the same day | ~$1–1.50 |

Main savings: Spot worker nodes, no NAT Gateway, a single ALB for the whole app, `kubectl port-forward` instead of extra load balancers, and a smaller Jenkins instance.

## Progress

- [x] **Phase 0** — local preparation (see below)
- [ ] **Session 1** — Jenkins, SonarQube and CI pipelines, images in ECR
- [ ] **Session 2** — EKS, AWS Load Balancer Controller, ArgoCD, Prometheus/Grafana
- [ ] **Cleanup** — zero resources left

---

## Phase 0 — Local preparation

Goal: do everything that costs nothing *before* creating any billable resource, so no paid minute is spent on setup or debugging.

### 1. AWS account security and cost guardrails

- **MFA** enabled on the root user and on the IAM admin user.
- A dedicated **IAM user** with `AdministratorAccess` is used for all work; the root user is only used for account-level settings.
- IAM user access to Billing enabled, so costs can be monitored without logging in as root.
- **AWS Budgets**: a monthly cost budget of **$3**, with e-mail alerts at 80% and 100% of *actual* costs.
  Credits are excluded from the budget so the alert reflects real usage even while promotional credits pay the bill.

> A budget only **alerts**, it never stops resources. Cleanup discipline is still required.

### 2. Local tooling (Windows + WSL 2)

All commands run in **Ubuntu on WSL 2**, because the project scripts are written in bash and `chmod` (needed for SSH keys) does not work reliably on Windows-mounted drives (`/mnt/c`). The project is therefore kept in the Linux home directory.

| Tool | Installation | Why |
| --- | --- | --- |
| AWS CLI v2 | Official installer from `awscli.amazonaws.com` (not the Ubuntu `snap`/`apt` packages, which ship v1 or an outdated v2) | Drive AWS from the terminal |
| Terraform ≥ 1.10 | Official HashiCorp APT repository | Provision the Jenkins server; ≥ 1.10 is required for native S3 state locking |
| Git | Ubuntu package | Version control, GitOps source of truth |

The CLI is configured with an access key for the IAM user and the default region `us-west-2`, then verified with:

```bash
aws sts get-caller-identity
chmod 600 ~/.aws/credentials   # WSL creates it world-readable by default
```

### 3. Tokens prepared in advance

| Token | Used by | Notes |
| --- | --- | --- |
| GitHub Personal Access Token (classic, `repo` scope, 30-day expiry) | Jenkins (checkout + pushing new image tags), `git push` over HTTPS | GitHub no longer accepts account passwords on the command line |
| NVD API key | OWASP Dependency-Check | Without it, downloading the vulnerability database can take hours |

Secrets are stored in a password manager, never in the repository, a chat or a screenshot.

### 4. Repository configuration

```bash
./configure.sh <aws-account-id> <github-user> <github-email> <tf-state-bucket>
grep -rn "__[A-Z_]*__" .   # only configure.sh itself should match
```

The script points the Jenkinsfiles, ArgoCD Applications, image references and Terraform backend to this account and this repository.

**Database credentials.** The default PostgreSQL password from the tutorial was replaced with a randomly generated one (`openssl rand -hex 12`), base64-encoded in `kubernetes-manifests/database/secrets.yaml`.
Base64 is an encoding, not encryption: this is acceptable here only because the database is exposed through a `ClusterIP` service and is unreachable from the internet. In production, the secret would come from AWS Secrets Manager (External Secrets Operator) or Sealed Secrets.

### 5. Bug fixed: environment variable order in the backend Deployment

In `kubernetes-manifests/backend/deployment.yaml`, the connection string was declared **before** the variables it references:

```yaml
env:
  - name: POSTGRES_CONN_STR
    value: postgresql://$(POSTGRES_USERNAME):$(POSTGRES_PASSWORD)@postgres-svc:5432/mydatabase
  - name: POSTGRES_USERNAME   # defined too late
  ...
```

Kubernetes only expands `$(VAR)` when `VAR` is defined **earlier in the same list**; otherwise the literal text is kept. The API would have received `$(POSTGRES_PASSWORD)` as its password and failed with 502 errors on `/api`.
Fix: `POSTGRES_CONN_STR` moved to the end of the `env` list, after `POSTGRES_USERNAME`, `POSTGRES_PASSWORD` and `POSTGRES_DB`.

### 6. Protecting secrets from Git

`.gitignore` excludes SSH keys (`*.pem`), Terraform plugins (`.terraform/`) and state files (`*.tfstate*`).
While editing it, an appended line was merged with the previous one (`.pem*.pem`) because the file had no trailing newline, which would have let the private SSH key be committed. Lesson: always verify ignore rules instead of trusting a visual check:

```bash
git check-ignore -v jenkins-server-terraform/devsecops-project.pem
```

A scan for Windows line endings (`grep -rlI $'\r' .`) also confirmed that no script contains `\r\n`, which would break the EC2 bootstrap script.

### 7. Terraform remote state and SSH key

```bash
# Remote state: versioned S3 bucket, native locking (no DynamoDB table)
aws s3api create-bucket --bucket <tf-state-bucket> --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning --bucket <tf-state-bucket> --versioning-configuration Status=Enabled

# SSH key for the Jenkins server (private key stays local, git-ignored)
cd jenkins-server-terraform
aws ec2 create-key-pair --key-name devsecops-project --region us-west-2 \
  --query KeyMaterial --output text > devsecops-project.pem
chmod 400 devsecops-project.pem

# Dry run: nothing is created, nothing is billed
terraform init && terraform validate && terraform plan
```

Storing the state remotely means `terraform destroy` can always find every resource it created, even if the local machine is lost.

**Exit criteria for Phase 0:** `terraform plan` shows the resources to create with no errors.

---

### 8. Hardening the Jenkins security group

The original Terraform opened ports 22, 80, 8080, 9000 and 9090 to the whole internet (`0.0.0.0/0` and `::/0`),
on a server whose IAM role has `AdministratorAccess`: a compromised Jenkins would mean a compromised AWS account.

- Only ports **22** (SSH), **8080** (Jenkins) and **9000** (SonarQube) are kept; Grafana and Prometheus are reached through `kubectl port-forward`.
- Ingress is restricted to a single IP through a required variable (no default, so it cannot be forgotten):

```bash
export TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32"
terraform plan
```

The IP is never written to the repository. If it changes, re-running `terraform apply` updates the security group in place.

## Credits

Based on [codewithmuh/three-tier-devsecops-project](https://github.com/codewithmuh/three-tier-devsecops-project) by Muhammad Rashid ([YouTube walkthrough](https://youtu.be/UNF5JdUEfh8)).