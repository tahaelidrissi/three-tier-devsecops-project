# Changes vs codewithmuh/three-tier-devsecops-project

Goal: make the project work in 2026 and cost as little as possible (~2–5 $ on AWS).

## First run
    ./configure.sh <aws-account-id> <github-user> <github-email> <tf-state-bucket> [repo-name]

## Fixes (things that are broken today)
- `scripts/tools-install.sh`: Jenkins repo key rotated in Dec 2025 (`jenkins.io-2026.key`, `debian-stable`),
  Jenkins now requires **Java 21**; kubectl was pinned to 1.28 (too old for current EKS); eksctl moved to `eksctl-io`;
  SonarQube image `sonarqube:community` + required `vm.max_map_count`; 4 GB swap added.
- `kubernetes-manifests/database/deployment.yaml`: `postgres:latest` -> `postgres:16`
  (Postgres 18+ images changed the data directory, the PV mount would break).
- `kubernetes-manifests/database/service.yaml`: `LoadBalancer` -> `ClusterIP` (DB was exposed to the internet + extra LB cost).
- Jenkinsfiles: removed the author's hardcoded SonarQube IP and tokens, repo URL, name and email.
  SonarQube URL/token now come from `withSonarQubeEnv('sonar-server')`; OWASP uses an NVD API key credential (`nvd-api-key`).
- Deployments: author's AWS account ID replaced by a placeholder; `imagePullSecrets` removed
  (EKS nodes pull from ECR through their IAM role; the docker-config secret expired after 12 h anyway).

## Cost reductions
- Jenkins EC2: `t2.2xlarge` -> `m7i-flex.large` (+ swap).
- `eks-cluster.yaml`: Spot nodes, **no NAT Gateway**, OIDC enabled at creation, 20 GB disks.
- One ALB for the whole app (`kubernetes-manifests/ingress/ingress.yaml`: `/` -> frontend, `/api` -> backend), no domain needed.
  The old `frontend-ingress` and `backend-ingress` folders were removed.
- Terraform state locking via S3 `use_lockfile` (no DynamoDB table).

## Additions
- `argocd/*.yaml`: declarative ArgoCD Applications (database, backend, frontend, ingress) with auto-sync.
- `06_iam-role.tf`: AdministratorAccess on the Jenkins instance role (**lab only**) so no access keys are copied to the server.
