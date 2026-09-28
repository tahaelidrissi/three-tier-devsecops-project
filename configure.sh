#!/usr/bin/env bash
# Replaces every __PLACEHOLDER__ in the repo with your own values. Run once, from the repo root:
#   ./configure.sh <aws-account-id> <github-user> <github-email> <tf-state-bucket-name> [repo-name]
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <aws-account-id> <github-user> <github-email> <tf-state-bucket> [repo-name]"; exit 1; }
ACCOUNT="$1"; GHUSER="$2"; GHMAIL="$3"; BUCKET="$4"; REPO="${5:-three-tier-devsecops-project}"
files=$(grep -rl '__[A-Z_]*__' --exclude=configure.sh --exclude-dir=.git . || true)
for f in $files; do
  sed -i.bak -e "s|__AWS_ACCOUNT_ID__|$ACCOUNT|g" -e "s|__GITHUB_USER__|$GHUSER|g" \
             -e "s|__GITHUB_EMAIL__|$GHMAIL|g" -e "s|__TF_STATE_BUCKET__|$BUCKET|g" \
             -e "s|__GITHUB_REPO__|$REPO|g" "$f" && rm -f "$f.bak"
  echo "updated: $f"
done
left=$(grep -rn '__[A-Z_]*__' --exclude=configure.sh --exclude-dir=.git . || true)
[ -z "$left" ] && echo "OK - no placeholders left" || { echo "Still to fix:"; echo "$left"; }
