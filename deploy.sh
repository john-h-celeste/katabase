#!/usr/bin/env bash

# chmod +x deploy.sh
#
# Usage:
#   ./deploy.sh <PROJECT_ID> [BRANCH]            build / update everything
#   ./deploy.sh <PROJECT_ID> --destroy [--yes]   delete everything Terraform created
#
# Options:
#   BRANCH       Git branch the VM should clone (default: the branch you have checked out)
#   --destroy    Tear down all resources (VM, data disk + database, network, secrets...)
#   --yes, -y    Skip the confirmation prompt when destroying

set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "[deploy] $*"; }

# ---------------------------------------------------------------- arguments passed to the script
PROJECT_ID=""
BRANCH=""
DESTROY=false
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --destroy)  DESTROY=true ;;
    --yes|-y)   ASSUME_YES=true ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $arg (try --help)" ;;
    *)
      if   [ -z "$PROJECT_ID" ]; then PROJECT_ID="$arg"
      elif [ -z "$BRANCH" ];     then BRANCH="$arg"
      else die "too many arguments (try --help)"
      fi
      ;;
  esac
done

[ -n "$PROJECT_ID" ] || { usage; exit 1; }

# ---------------------------------------------------------------- environment
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

command -v terraform >/dev/null || die "terraform not found (it is preinstalled in Cloud Shell)"
command -v gcloud    >/dev/null || die "gcloud not found"
command -v git       >/dev/null || die "git not found"

REPO_URL="$(git config --get remote.origin.url || true)"
[ -n "$REPO_URL" ] || die "no git remote 'origin' found; run this from a clone of your GitHub repo"
REPO_URL="$(echo "$REPO_URL" | sed -E 's#^git@github\.com:#https://github.com/#')"

if [ -z "$BRANCH" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

log "project: ${PROJECT_ID}"
log "repo:    ${REPO_URL}"
log "branch:  ${BRANCH}"

gcloud config set project "$PROJECT_ID" >/dev/null
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com --project ${PROJECT_ID}

TF_VARS=(
  -var "project_id=${PROJECT_ID}"
  -var "repo_url=${REPO_URL}"
  -var "repo_branch=${BRANCH}"
)

cd "${ROOT_DIR}/terraform"
terraform init -input=false

# ---------------------------------------------------------------- destroy the vm (to save on credits)
if [ "$DESTROY" = true ]; then
  echo
  echo "This will DELETE everything Terraform created in project '${PROJECT_ID}':"
  echo "  the VM, the data disk (database + staged models), the network, firewall rules,"
  echo "  the static IP, the secret, and the service account."
  echo
  if [ "$ASSUME_YES" != true ]; then
    read -r -p "Type the project ID to confirm: " CONFIRM
    [ "$CONFIRM" = "$PROJECT_ID" ] || die "confirmation did not match; nothing was deleted"
  fi
  terraform destroy -auto-approve -input=false "${TF_VARS[@]}"
  log "Everything has been destroyed."
  exit 0
fi

# ---------------------------------------------------------------- deploy as a vm
# Fail early if the VM would not be able to clone the branch.
git ls-remote --exit-code --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1 \
  || die "branch '${BRANCH}' not found at ${REPO_URL} (is it pushed? is the repo public?)"

[ -f "${ROOT_DIR}/scripts/startup.sh" ] || die "scripts/startup.sh is missing"

terraform validate

for attempt in 1 2; do
  if terraform apply -auto-approve -input=false "${TF_VARS[@]}"; then
    break
  fi
  [ "$attempt" -lt 2 ] || die "terraform apply failed twice; read the errors above"
  log "apply failed; waiting 60s and retrying once (APIs may still be enabling)"
  sleep 60
done

echo
log "Infrastructure is up. The VM is now running its startup script (several minutes)."
terraform output