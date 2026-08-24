#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STACK_DIR="$ROOT_DIR/stacks/00-state-bootstrap"
TFVARS="$ROOT_DIR/environments/prod/terraform.tfvars"
PROJECT_ID="tesseracthub-480811"
STATE_BUCKET="tesseract-terraform-states"
EXECUTE="${1:-}"

for command_name in gcloud terraform; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: %s is required\n' "$command_name" >&2
    exit 1
  }
done

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)"
active_project="$(gcloud config get-value project 2>/dev/null)"

printf 'Active account: %s\n' "${active_account:-<none>}"
printf 'Active project: %s\n' "${active_project:-<none>}"
printf 'Intended target: gs://%s in project %s\n' "$STATE_BUCKET" "$PROJECT_ID"

[[ -n "$active_account" ]] || {
  printf 'error: no active gcloud account\n' >&2
  exit 1
}
[[ "$active_project" == "$PROJECT_ID" ]] || {
  printf 'error: active project must be %s\n' "$PROJECT_ID" >&2
  exit 1
}

capture_dir="$ROOT_DIR/bootstrap-captures/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$capture_dir"
gcloud storage buckets describe "gs://$STATE_BUCKET" --format=json \
  >"$capture_dir/bucket.json"
gcloud storage ls --recursive "gs://$STATE_BUCKET/**" \
  >"$capture_dir/objects.txt"
printf 'Read-only capture: %s\n' "$capture_dir"

if [[ "$EXECUTE" != "--execute" ]]; then
  printf 'Preflight only. No Terraform state was changed.\n'
  exit 0
fi

[[ "${CONFIRM_STATE_BUCKET_IMPORT:-}" == "$STATE_BUCKET" ]] || {
  printf 'error: set CONFIRM_STATE_BUCKET_IMPORT=%s for the approved import\n' "$STATE_BUCKET" >&2
  exit 1
}

terraform -chdir="$STACK_DIR" init -input=false
if terraform -chdir="$STACK_DIR" state show google_storage_bucket.terraform_state \
  >/dev/null 2>&1; then
  printf 'State bucket is already imported; skipping import.\n'
else
  terraform -chdir="$STACK_DIR" import \
    -input=false \
    -var-file="$TFVARS" \
    google_storage_bucket.terraform_state \
    "$STATE_BUCKET"
fi

terraform -chdir="$STACK_DIR" plan \
  -input=false \
  -var-file="$TFVARS" \
  -out=00-state-bootstrap.tfplan
printf 'Import complete. Review the saved plan; this script does not apply it.\n'
