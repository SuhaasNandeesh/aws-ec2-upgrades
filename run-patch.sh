#!/usr/bin/env bash
set -euo pipefail

# run-patch.sh - entry point for the patching automation.
# Usage:
#   ./run-patch.sh                          # patch all hosts in inventory/targets.yml
#   ./run-patch.sh --limit prod             # patch only the prod group
#   ./run-patch.sh --bootstrap              # auto-attach SSM IAM profiles to unready instances
#   ./run-patch.sh --no-snapshot            # skip pre-patch EBS snapshots
#   ./run-patch.sh --dry-run                # Ansible check mode (no changes)
#   ./run-patch.sh --region eu-central-1    # override region for all groups
#   ./run-patch.sh -e key=value             # pass extra vars to ansible-playbook

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AWS_PROFILE="${AWS_PROFILE:-default}"
BOOTSTRAP="false"
SNAPSHOT="true"
CHECK=""
LIMIT=""
REGION=""
EXTRA_VARS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)    BOOTSTRAP="true"; shift ;;
    --no-snapshot)  SNAPSHOT="false"; shift ;;
    --check)        CHECK="--check"; shift ;;
    --dry-run)      CHECK="--check"; shift ;;
    --limit)        LIMIT="--limit $2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    -e)             EXTRA_VARS="$EXTRA_VARS -e $2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ ! -f inventory/targets.yml ]]; then
  echo "ERROR: inventory/targets.yml not found. Copy inventory/targets.yml.example and fill in instance IDs."
  exit 1
fi

# Validate that at least one group_vars file exists and has ssm_bucket_name set
GV_VALIDATED=false
for _gv in inventory/group_vars/prod.yml inventory/group_vars/nonprod.yml; do
  if [[ -f "$_gv" ]]; then
    _bucket=$(grep 'ssm_bucket_name:' "$_gv" | sed 's/.*ssm_bucket_name:\s*//' | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs)
    if [[ -z "$_bucket" ]]; then
      echo "ERROR: ssm_bucket_name is empty in $_gv. Set it to an S3 bucket in the target account."
      exit 1
    fi
    GV_VALIDATED=true
  fi
done
if [[ "$GV_VALIDATED" == "false" ]]; then
  echo "ERROR: No group_vars files found. Copy inventory/group_vars/prod.yml.example and/or nonprod.yml.example to .yml and fill in values."
  exit 1
fi

RUN_DATE="$(date +%Y-%m-%d)"
REPORT_DIR="reports/${RUN_DATE}"
mkdir -p "$REPORT_DIR"

echo "=== EC2 Patch Automation ==="
echo "Date:      $RUN_DATE"
echo "Profile:   $AWS_PROFILE"
echo "Bootstrap: $BOOTSTRAP"
echo "Snapshot:  $SNAPSHOT"
if [[ -n "$REGION" ]]; then
  echo "Region:    $REGION (override)"
fi
echo "Reports:   $REPORT_DIR"
echo "================================"

export AWS_PROFILE
export ANSIBLE_COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH:-$SCRIPT_DIR/collections}"

REGION_VAR=""
if [[ -n "$REGION" ]]; then
  REGION_VAR="-e aws_region=${REGION}"
fi

ansible-playbook playbooks/patch.yml \
  -i inventory/targets.yml \
  -e "run_date=${RUN_DATE}" \
  -e "report_dir=${REPORT_DIR}" \
  -e "bootstrap=${BOOTSTRAP}" \
  -e "snapshot=${SNAPSHOT}" \
  ${REGION_VAR} \
  ${LIMIT} ${CHECK} ${EXTRA_VARS}

echo ""
echo "Reports written to: ${REPORT_DIR}/"