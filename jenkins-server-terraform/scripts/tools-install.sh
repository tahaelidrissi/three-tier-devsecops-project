#!/bin/bash
# Jenkins server bootstrap - Ubuntu 22.04 (runs as root via EC2 user data)
# Log: /var/log/cloud-init-output.log   -> check it with: sudo tail -f /var/log/cloud-init-output.log
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- 4 GB swap (m7i-flex.large has 8 GB RAM; Jenkins + SonarQube + OWASP need headroom)
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# --- Kernel settings required by SonarQube (Elasticsearch)
cat > /etc/sysctl.d/99-sonarqube.conf <<SYSCTL
vm.max_map_count=524288
fs.file-max=131072
SYSCTL
sysctl --system

apt-get update -y
apt-get install -y fontconfig openjdk-21-jre curl wget unzip gnupg lsb-release apt-transport-https jq

# --- Jenkins LTS (Java 21 required; repo key rotated in Dec 2025 -> jenkins.io-2026.key)
mkdir -p /etc/apt/keyrings
wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins

# --- Docker
apt-get install -y docker.io
usermod -aG docker jenkins
usermod -aG docker ubuntu
systemctl enable --now docker
systemctl restart jenkins

# --- SonarQube Community Build (port 9000), restarts automatically with Docker
docker run -d --name sonar --restart unless-stopped -p 9000:9000 sonarqube:community

# --- AWS CLI v2
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install

# --- kubectl (current stable, to match the EKS version eksctl creates)
KVER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
curl -sSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# --- eksctl
curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

# --- Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Trivy
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" > /etc/apt/sources.list.d/trivy.list
apt-get update -y && apt-get install -y trivy

echo "=== BOOTSTRAP DONE ===" 
