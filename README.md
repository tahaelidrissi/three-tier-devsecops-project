# Three-Tier DevSecOps Application on AWS EKS

![AWS](https://img.shields.io/badge/AWS-EKS%20%7C%20EC2%20%7C%20ECR%20%7C%20S3-orange)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC)
![Jenkins](https://img.shields.io/badge/CI-Jenkins-D24939)
![ArgoCD](https://img.shields.io/badge/CD-ArgoCD%20(GitOps)-EF7B4D)
![Security](https://img.shields.io/badge/DevSecOps-SonarQube%20%7C%20OWASP%20%7C%20Trivy-2E8B57)
![Monitoring](https://img.shields.io/badge/Monitoring-Prometheus%20%7C%20Grafana-E6522C)

End-to-end DevSecOps deployment of a three-tier notes application (React frontend, Django REST API, PostgreSQL) on Amazon EKS:
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
                   └─  /api  ──► backend (Django)  ──► PostgreSQL
     Prometheus + Grafana (namespace monitoring)
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `app-code/` | Application source: React frontend and Django (Python) backend |
| `jenkins-server-terraform/` | Terraform for the Jenkins server (VPC, EC2, IAM role, bootstrap script) |
| `jenkins-pipeline/` | Jenkinsfiles for the backend and frontend pipelines |
| `kubernetes-manifests/` | Kubernetes objects: database, backend, frontend, ingress |
| `argocd/` | Declarative ArgoCD Applications (auto-sync) |
| `eks-cluster.yaml` | EKS cluster definition for `eksctl` (2 on-demand `m7i-flex.large` nodes, no NAT Gateway) |
| `configure.sh` | Replaces every `__PLACEHOLDER__` with account-specific values |
| `CHANGES.md` | Fixes and cost optimizations compared to the original tutorial |

## Cost strategy

AWS bills by the hour, and the EKS control plane is the most expensive piece. The project is therefore split so that the cluster only exists for a few hours:

| Phase | What runs on AWS | Estimated cost | Actual |
| --- | --- | --- | --- |
| Phase 0 — local preparation | Nothing (S3 state bucket only) | ~$0 | ~$0 |
| Session 1 — CI | Jenkins EC2 only | ~$0.30 | ~$0.40 (≈4 h, see below) |
| Session 2 — CD & monitoring | Jenkins + EKS + 1 ALB, destroyed the same day | ~$1–1.50 | ~$0.70 (≈1 h 15 of cluster, see below) |
| **Total** | | **~$2–5** | **≈ $1.20** |

Main savings: the cluster only exists for about an hour, no NAT Gateway, a single ALB for the whole app, `kubectl port-forward` instead of extra load balancers, and a smaller Jenkins instance.

## Issues found and fixed

Problems discovered while preparing (Phase 0) and running (Sessions 1 and 2) the project:

| # | Issue | Impact if left as is | Fix |
| --- | --- | --- | --- |
| 1 | Backend `env` list referenced `$(POSTGRES_PASSWORD)` before defining it | `POSTGRES_CONN_STR` held the literal text instead of the password (latent bug: Django does not read this variable today) | Reordered the `env` list ([details](#5-latent-bug-fixed-environment-variable-order-in-the-backend-deployment)) |
| 2 | Jenkins security group open to `0.0.0.0/0` on 5 ports, on an instance with `AdministratorAccess` | An exposed Jenkins could lead to a full AWS account takeover | 3 ports, single allowed IP ([details](#8-hardening-the-jenkins-security-group)) |
| 3 | Broken `.gitignore` rule (`.pem*.pem`) | Private SSH key committed to a public repository | Fixed and verified with `git check-ignore` ([details](#6-protecting-secrets-from-git)) |
| 4 | Default PostgreSQL password from the tutorial | Publicly known credential | Random password ([details](#4-repository-configuration)) |
| 5 | Backend `requirements.txt` listed ~150 packages (pandas, transformers, Selenium, Scrapy…) while the code only imports 5 | Multi-GB image, slow builds billed by the hour, hundreds of irrelevant CVEs in Trivy/OWASP reports | Trimmed to the 5 packages actually used |
| 6 | Frontend `Dockerfile` copied only `package.json` and ran `npm install` | Non-reproducible build: a newer transitive `eslint-plugin-jest` broke `react-scripts build` (`Environment key "jest/globals" is unknown`) | `COPY package-lock.json` + `npm ci` ([details](#frontend-build-failure-non-reproducible-dependencies)) |
| 7 | Jenkinsfiles interpolate secrets in Groovy strings (`"--nvdApiKey ${NVD_API_KEY}"`) | Masked in Jenkins logs, but the NVD key is visible in clear text in the server process list (`ps`) | **Open** — to fix with single-quoted `sh` / environment variables; key to be rotated ([details](#secrets-interpolated-in-groovy-strings-open)) |
| 8 | Local network only allowed outbound HTTPS (ports 22, 80 and 8080 blocked) | No SSH and no access to Jenkins/SonarQube from that network | SSH tunnel from an unrestricted network; AWS Systems Manager (HTTPS-only) as the long-term option ([details](#restricted-network-only-https-allowed)) |
| 9 | `eks-cluster.yaml` requested Spot `t3.medium`/`t3.large` nodes | On an AWS **Free plan** account only a few instance types are allowed: the node group would have failed mid-creation | 2 on-demand `m7i-flex.large` nodes ([details](#1-checking-that-eks-is-allowed-on-a-free-plan-account)) |
| 10 | No `resources.requests`/`limits` on any Deployment | The scheduler cannot place pods reliably and one pod can starve its neighbours (visible in Grafana: *CPU Throttling — No data*) | **Open** — see [Next steps](#next-steps) |

Fixes inherited from the original tutorial (Jenkins 2026 repository key, Java 21, `postgres:16`, cost reductions…) are listed in [`CHANGES.md`](CHANGES.md).

## Progress

- [x] **Phase 0** — local preparation (see below)
- [x] **Session 1** — Jenkins, SonarQube and CI pipelines, images in ECR (see below)
- [x] **Session 2** — EKS, AWS Load Balancer Controller, ArgoCD, Prometheus/Grafana (see below)
- [x] **Cleanup** — zero resources left

> **Status:** project completed on 29 September 2026. All AWS resources have been destroyed.

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

### 5. Latent bug fixed: environment variable order in the backend Deployment

In `kubernetes-manifests/backend/deployment.yaml`, the connection string was declared **before** the variables it references:

```yaml
env:
  - name: POSTGRES_CONN_STR
    value: postgresql://$(POSTGRES_USERNAME):$(POSTGRES_PASSWORD)@postgres-svc:5432/mydatabase
  - name: POSTGRES_USERNAME   # defined too late
  ...
```

Kubernetes only expands `$(VAR)` when `VAR` is defined **earlier in the same list**; otherwise the literal text is kept, so `POSTGRES_CONN_STR` contained `$(POSTGRES_PASSWORD)` instead of the real password.

On closer inspection, the Django backend does not read `POSTGRES_CONN_STR` at all: `core/settings.py` builds the connection from `POSTGRES_USERNAME`, `POSTGRES_PASSWORD` and `POSTGRES_DB` directly. The bug is therefore **latent**: harmless today, but any code relying on the connection string would break silently.
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

> Consumer VPNs such as Cloudflare WARP change the public egress IP, so they are disabled during AWS sessions to keep the allowed IP valid.

### 9. Git hygiene

- **Commit identity.** Commits made before `user.email` was configured used a machine-generated address (`user@hostname.localdomain`) and were not linked to the GitHub profile. The identity was set to the e-mail registered on GitHub, and the author of every commit was rewritten:

  ```bash
  git config --global user.email "<email-registered-on-github>"
  git rebase -r --root --exec "git commit --amend --no-edit --reset-author"
  git push --force-with-lease
  ```

- **`--force-with-lease` instead of `--force`.** The first forced push was rejected (`stale info`) because a commit had been made from the GitHub web UI in the meantime. Unlike `--force`, `--force-with-lease` refuses to overwrite remote work it has not seen. After `git fetch` and a review with `git diff --stat origin/main main`, the push went through safely.
- **Rules kept for the rest of the project:** always `git pull` after editing on github.com, and never rewrite the history of a shared branch.

### Phase 0 outcome

- `terraform plan`: **12 resources to add, 0 errors**; the S3 state lock is acquired and released correctly.
- Repository configured, documented and pushed; no secret committed.
- AWS cost so far: **~$0** (only an almost empty S3 bucket).

---

## Session 1 — Jenkins, SonarQube and CI pipelines

Goal: both CI pipelines green, images pushed to Amazon ECR and new image tags committed back to this repository. The EKS cluster does not exist yet.

**Result:** ✅ `backend` build #2 and `frontend` build #3 green, images `backend:2` and `frontend:3` in ECR, and two commits pushed by Jenkins (`ci(backend): deploy image 2`, `ci(frontend): deploy image 3`).

### 1. Provisioning the Jenkins server

```bash
export TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32"
terraform apply                                     # 12 resources, ~1 min
aws ecr create-repository --repository-name backend  --region us-west-2
aws ecr create-repository --repository-name frontend --region us-west-2
```

The EC2 user data script installed everything in **under 3 minutes** (`=== BOOTSTRAP DONE ===` in `/var/log/cloud-init-output.log`):
Java 21, Jenkins LTS, Docker, SonarQube Community Build (container), AWS CLI v2, kubectl, eksctl, Helm and Trivy, plus a 4 GB swap file.
The server uses its **IAM instance role**: no AWS access key was ever copied onto it.

### 2. Accessing Jenkins and SonarQube through an SSH tunnel

Instead of browsing to the public IP, both UIs are reached through SSH port forwarding:

```bash
ssh -o ServerAliveInterval=60 -i devsecops-project.pem -N \
  -L 8080:localhost:8080 -L 9000:localhost:9000 ubuntu@<jenkins-public-ip>
# then http://localhost:8080 (Jenkins) and http://localhost:9000 (SonarQube)
```

Traffic to the plain-HTTP UIs is encrypted and authenticated by the SSH key, and it does not depend on the browser's egress IP (VPN or browser proxies).
`ServerAliveInterval` keeps idle sessions from being dropped by home routers.

### 3. SonarQube configuration

- Admin password changed at first login.
- **Global Analysis Token** generated for Jenkins (30-day expiry).
- **Webhook** to `http://<jenkins-private-ip>:8080/sonarqube-webhook/`, so that the pipeline's Quality Gate step is notified as soon as the analysis is processed.
  The private IP is used because SonarQube runs in a Docker container: from inside it, `localhost` is the container itself, not the host.

### 4. Jenkins configuration

**Plugins** (on top of the suggested ones): SonarQube Scanner, OWASP Dependency-Check, NodeJS, Eclipse Temurin installer, Docker Pipeline, Pipeline: AWS Steps.

**Tools**, installed automatically on first use (names must match the Jenkinsfiles exactly):

| Tool | Name | Installer |
| --- | --- | --- |
| JDK | `jdk` | Adoptium, JDK 21 |
| SonarQube Scanner | `sonar-scanner` | Maven Central |
| NodeJS | `nodejs` | Node.js 22 LTS |
| Dependency-Check | `DP-Check` | GitHub releases |

**Credentials** (values never stored in the repository; Jenkins masks them in build logs):

| ID | Type | Used for |
| --- | --- | --- |
| `GITHUB` | Username with password (GitHub PAT) | Git checkout |
| `github` | Secret text (same PAT) | Pushing the new image tag |
| `sonar-token` | Secret text | SonarQube analysis and Quality Gate |
| `nvd-api-key` | Secret text | OWASP Dependency-Check |
| `ACCOUNT_ID` | Secret text | ECR registry URL |
| `ECR_REPO_BACKEND` / `ECR_REPO_FRONTEND` | Secret text | ECR repository names |

**SonarQube server** `sonar-server` → `http://localhost:9000` with the `sonar-token` credential (Jenkins and SonarQube run on the same host).

**Pipelines**: two *Pipeline script from SCM* jobs (`backend`, `frontend`) reading `jenkins-pipeline/jenkinsfile-*` from this repository (pipeline as code).

### 5. What each pipeline does

| Stage | Tool | Purpose |
| --- | --- | --- |
| Sonarqube Analysis | SonarScanner | Static analysis (SAST), code smells, secrets detection |
| Quality Check | SonarQube Quality Gate | Waits for the verdict through the webhook |
| OWASP Dependency-Check | Dependency-Check + NVD | Known CVEs in third-party dependencies (SCA) |
| Trivy File Scan | Trivy | Vulnerabilities and secrets in the source tree |
| Docker Image Build | Docker | Builds the application image |
| ECR Image Pushing | AWS CLI + Docker | Pushes `<repo>:<build number>` to ECR |
| Trivy Image Scan | Trivy | Vulnerabilities in the final image (OS packages + libraries) |
| Update Deployment file (GitOps) | Git | Replaces the image tag in `kubernetes-manifests/<app>/deployment.yaml` and pushes the commit that ArgoCD will deploy in Session 2 |

Results: **Quality Gate passed** for both projects. The Trivy and Dependency-Check reports are archived with each build.
`npm` reported **28 vulnerabilities (9 low, 5 moderate, 14 high)** in the frontend dependencies, expected with the unmaintained `react-scripts 5`; they are documented, not yet remediated.

### 6. Problems met during Session 1

#### First OWASP scan: a 400,000-record database

The first Dependency-Check run downloads the whole NVD database (**398,740 CVE records**). With the NVD API heavily rate-limited that evening, the download took **about 3 hours**.
The database is cached on the Jenkins disk: the next run (frontend) skipped the update and completed the analysis in **2 seconds**.
This is why the instance is **stopped, not destroyed**, between sessions.

#### Frontend build failure: non-reproducible dependencies

```
[eslint] package.json » eslint-config-react-app/jest#overrides[0]:
	Environment key "jest/globals" is unknown
```

The `Dockerfile` copied only `package.json` and ran `npm install`, so npm resolved the *latest* versions matching the `^` ranges. A newer major version of a transitive dependency (`eslint-plugin-jest`) is incompatible with `react-scripts 5`.
The repository already contained a `package-lock.json` pinning a working version (`eslint-plugin-jest 25.7.0`), but it was ignored. Fix:

```dockerfile
COPY package.json package-lock.json /app/
RUN npm ci
```

`npm ci` installs exactly the locked versions: the same commit always produces the same image.

#### Secrets interpolated in Groovy strings (open)

Jenkins warned: *"A secret was passed to "dependencyCheck" using Groovy String interpolation, which is insecure."*
With `"--nvdApiKey ${NVD_API_KEY}"` (double quotes), Groovy inserts the secret into the command line itself: Jenkins masks it in the build log, but any user on the server can read it with `ps`.
Planned fix: pass secrets through environment variables and single-quoted `sh` steps (or the plugin's dedicated credential parameter), then rotate the NVD key.

#### Restricted network: only HTTPS allowed

From one network, SSH and Jenkins timed out although the security group allowed the current IP and AWS status checks were green. A test against `portquiz.net` confirmed that ports 22, 80 and 8080 were blocked outbound; only 443 worked.
Working from another network (with `terraform apply` to update the allowed IP) solved it. **AWS Systems Manager Session Manager**, which tunnels over HTTPS and needs no open inbound port, is the long-term option.

#### Small configuration mistakes

- `No installation DP-Check found`: the tool name must match the Jenkinsfile exactly.
- `Unable to find Jenkinsfilejenkins-pipeline/...`: the default `Jenkinsfile` value was not removed from the *Script Path* field.
- The AWS console showed "no instances": it was set to another region. Resources live in **us-west-2 (Oregon)**.

### Session 1 outcome

- 2 green pipelines, 2 images in ECR, 2 GitOps commits by Jenkins.
- Instance **stopped** at the end of the session: Jenkins configuration, credentials, SonarQube data and the NVD cache persist on the 30 GB disk (~$0.08/day). The public IP changes on restart.
- AWS cost: **~$0.40** (about 4 hours of `m7i-flex.large`), paid by credits.

---

## Session 2 — EKS, ArgoCD and monitoring

Goal: run the application on Amazon EKS behind an ALB, deployed by ArgoCD from this repository, monitored with Prometheus and Grafana, and destroy everything the same day.

**Result:** ✅ application online, 4 ArgoCD Applications *Synced / Healthy*, GitOps demo recorded (code change → Jenkins → new image tag → ArgoCD → rolling update), Grafana dashboards, and a complete cleanup.

All cluster commands run **on the Jenkins server**, which already has `kubectl`, `eksctl` and `helm`, and uses its IAM role (no access key).

### 1. Checking that EKS is allowed on a Free plan account

The account is on the AWS **Free plan** (no card charges, credits only). The documentation does not clearly list EKS as blocked, so it was tested directly with a bare control plane (no nodes), deleted as soon as it became active:

```bash
aws eks create-cluster --name eks-free-plan-test --role-arn <test-role> \
  --resources-vpc-config subnetIds=<2 default subnets> --query cluster.status   # → CREATING
aws eks wait cluster-active  --name eks-free-plan-test && aws eks delete-cluster --name eks-free-plan-test
```

Cost of the test: a few cents. **EKS works on the Free plan**, but EC2 is restricted to a few instance types (`t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`, `m7i-flex.large`).
The original node group (Spot `t3.medium`/`t3.large`) was therefore replaced **before** creating the cluster:

```yaml
managedNodeGroups:
  - name: ng-1
    instanceTypes: ["m7i-flex.large"]   # 2 vCPU, 8 GiB, Free-plan eligible
    spot: false
    desiredCapacity: 2
```

### 2. Creating the cluster

```bash
tmux new -s eks                      # survives an SSH disconnection
eksctl create cluster -f eks-cluster.yaml
```

`eksctl` generated two CloudFormation stacks and the cluster was ready in **16 minutes**:

| Component | Details |
| --- | --- |
| VPC | Dedicated `192.168.0.0/16`, public and private subnets in 3 AZs, **no NAT Gateway** (nodes in public subnets) |
| Control plane | Kubernetes **1.34**, managed by AWS |
| Add-ons | `vpc-cni` (pods get VPC IPs), `kube-proxy`, `coredns`, `metrics-server` |
| IAM OIDC provider | Enables IRSA: pods get AWS permissions through a Kubernetes service account, without access keys |
| Node group | 2 × `m7i-flex.large`, Amazon Linux 2023, containerd |

> `eksctl` warns that OIDC is disabled when it creates the `vpc-cni` add-on: this is only an ordering message, the provider is associated right after. Verified with `aws eks describe-cluster --query cluster.identity.oidc.issuer`.

### 3. AWS Load Balancer Controller

The controller watches `Ingress` objects and creates the corresponding **Application Load Balancer**. Its IAM policy must match the installed version, so the version is read from the Helm chart first:

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
LBC_VERSION=$(helm search repo eks/aws-load-balancer-controller -o json | jq -r '.[0].app_version')   # v3.5.0
curl -fsSL -o iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json

eksctl create iamserviceaccount --cluster $CLUSTER --namespace kube-system \
  --name aws-load-balancer-controller --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy --approve

helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=$CLUSTER --set region=$REGION --set vpcId=$VPC_ID \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller
```

A mismatched policy is one of the most common failures of this setup: the controller starts, then fails with `AccessDenied` when it tries to create the ALB.

### 4. ArgoCD and GitOps deployment

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/          # 4 Applications: database, backend, frontend, ingress
```

- `--server-side` is required because some ArgoCD CRDs are too large for a client-side `kubectl apply`.
- Each Application points to a folder of `kubernetes-manifests/` in this repository, with `automated`, `prune` and `selfHeal`: Git is the single source of truth, manual changes in the cluster are reverted.
- ArgoCD deployed PostgreSQL, the Django API (2 replicas, image `backend:2`), the React frontend (`frontend:3`) and the Ingress. The `api` pods restarted once or twice at startup because they started before PostgreSQL was ready, then stabilised.
- The ArgoCD UI is **not exposed**: it is reached with `kubectl port-forward` on the server, through the SSH tunnel.

**One ALB for the whole application** (`kubernetes-manifests/ingress/ingress.yaml`, `target-type: ip`):

| Path | Service | Check |
| --- | --- | --- |
| `/` | `frontend:3000` (React) | `HTTP 200` |
| `/api` | `api:8000` (Django REST) | `GET /api/notes/` → `HTTP 200 []` |

All ALB targets (the pod IPs) were `healthy`. Creating a note in the browser and reloading the page confirmed that the three tiers communicate (frontend → API → PostgreSQL).

### 5. GitOps demo: from `git push` to production

1. Change the page title in `app-code/frontend/notes-frontend/src/components/Notes.js`, commit and push.
2. Run the `frontend` pipeline: SonarQube, OWASP (NVD cache reused), Trivy, build, push `frontend:4` to ECR.
3. Jenkins commits `ci(frontend): deploy image 4` to `kubernetes-manifests/frontend/deployment.yaml`.
4. ArgoCD detects the commit (polling every 3 minutes, or *Refresh*) and performs a rolling update.
5. The new title *"Notes List — deployed by ArgoCD (GitOps)"* is live, with the existing notes still stored in PostgreSQL.

**No `kubectl apply` was run for this deployment**: the cluster only follows Git.

> The pipeline itself is started manually. An automatic trigger is a planned improvement (see [Next steps](#next-steps)): it must be restricted to each app's folder, otherwise Jenkins would be re-triggered by its own `ci(...)` commit and loop forever.

### 6. Monitoring with Prometheus and Grafana

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace --set alertmanager.enabled=false
```

- **Prometheus** scrapes node-exporter (one per node), kube-state-metrics, the kubelets and the API server every 30 s. All targets were *UP*.
- **Grafana** ships with ready-made dashboards: *Kubernetes / Compute Resources / Namespace (Pods)* for `three-tier`, *Cluster*, and *Node Exporter / Nodes*.
- A small load test through the ALB (GET `/`, GET and POST `/api/notes/` in a loop for 3 minutes) made the `api` CPU rise from ~0 to **~40 millicores**: the Django API is very light.
- *CPU Throttling* showed *No data* because no CPU limits are defined on the containers (issue #10).
- Both UIs were reached with `kubectl port-forward` through the SSH tunnel: **no extra load balancer**.

PromQL queries used:

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="three-tier"}[2m]))
sum by (pod) (container_memory_working_set_bytes{namespace="three-tier", container!=""})
kube_pod_container_status_restarts_total{namespace="three-tier"}
```

### 7. Problems met during Session 2

- **Browser DNS cache.** The ALB was opened in the browser before its DNS name existed; the browser cached the failure (`DNS_PROBE_POSSIBLE`) while `curl` from the server already returned `200`. Fixed by clearing the browser host cache and `ipconfig /flushdns`. Lesson: test from the server first (`getent hosts`, `curl -w %{http_code}`, target health) before blaming the application.
- **A misleading network test.** A connectivity check that searched for a text string in a web page reported ports as blocked when they were not; checking the HTTP status code (`curl -w "%{http_code}"`) gave the right answer.
- **tmux habits.** Long-running commands (`eksctl`, `kubectl port-forward`) were run in separate tmux windows so that an SSH disconnection could not interrupt them.

## Cleanup

The order matters:

1. **Delete the ArgoCD Applications first.** With `selfHeal: true`, ArgoCD would immediately recreate a manually deleted Ingress, and the ALB with it. Without a finalizer, deleting an Application does not delete its resources.
2. **Delete the Ingress** → the controller deletes the ALB. Wait until `aws elbv2 describe-load-balancers` returns nothing: a remaining ALB blocks the deletion of the VPC.
3. **Delete the cluster**, then the controller's IAM policy.
4. **Destroy the Jenkins server**, then the ECR repositories, the key pair and the versioned state bucket (emptied first, since `aws s3 rb` does not remove object versions).

```bash
# On the Jenkins server
kubectl delete -f argocd/
kubectl delete ingress --all -n three-tier
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"      # wait for []
eksctl delete cluster -f eks-cluster.yaml --disable-nodegroup-eviction --wait
aws iam delete-policy --policy-arn arn:aws:iam::<account-id>:policy/AWSLoadBalancerControllerIAMPolicy

# On the workstation
terraform destroy                                     # TF_VAR_allowed_cidr is required even to destroy
aws ecr delete-repository --repository-name backend  --force
aws ecr delete-repository --repository-name frontend --force
aws ec2 delete-key-pair --key-name devsecops-project
# S3 console: Empty, then Delete the tfstate bucket
```

A final check listed no EKS cluster, no running instance, no EBS volume, no load balancer, no Elastic IP, no `eksctl-*` CloudFormation stack, no ECR repository and no key pair; only the account's default VPC remains.
Last step: revoke the GitHub token used by Jenkins and rotate the NVD API key.

### Session 2 outcome

- Application deployed on EKS by ArgoCD, reachable through a single ALB, monitored with Prometheus and Grafana.
- Complete GitOps loop demonstrated: `git push` → Jenkins → ECR → Git commit → ArgoCD → rolling update.
- Cluster lifetime: about **1 h 15**. AWS cost of the session: **≈ $0.70**; whole project: **≈ $1.20**, paid by credits.

## Next steps

- **Fix issue #7**: pass secrets to the pipelines through environment variables and single-quoted `sh` steps, then rotate the NVD key.
- **Add `resources.requests` and `limits`** to every Deployment (issue #10), plus readiness/liveness probes for the frontend.
- **Automatic CI trigger** with *Poll SCM* restricted to each app's folder (`app-code/frontend/**`, `app-code/backend/**`), and `poll: false` on the in-pipeline `git` step to avoid the CI-commit loop.
- **Harden the application**: Django `SECRET_KEY` from a Kubernetes Secret, `DEBUG = False`, restricted `ALLOWED_HOSTS`, `gunicorn` instead of `runserver`, frontend base image `node:22-alpine` + static files served by nginx.
- **Secrets management**: AWS Secrets Manager with External Secrets Operator (or Sealed Secrets) instead of base64 Secrets in Git.
- **Persistent storage**: replace the `hostPath` PersistentVolume with a `gp3` EBS volume (EBS CSI driver), or Amazon RDS for PostgreSQL.
- **Single IaC tool**: manage the EKS cluster with the `terraform-aws-modules/eks` module instead of `eksctl`.
- **Access without open ports**: AWS Systems Manager Session Manager instead of SSH.

---

## Credits

Based on [codewithmuh/three-tier-devsecops-project](https://github.com/codewithmuh/three-tier-devsecops-project) by Muhammad Rashid ([YouTube walkthrough](https://youtu.be/UNF5JdUEfh8)).