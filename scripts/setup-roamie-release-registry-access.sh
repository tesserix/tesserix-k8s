#!/usr/bin/env bash
set -euo pipefail

release_action=${1:---plan}
if [[ $# -gt 1 || ( "$release_action" != --plan && "$release_action" != --apply ) ]]; then
  echo 'Usage: setup-roamie-release-registry-access.sh [--plan|--apply]' >&2
  exit 2
fi

release_project=tesseracthub-480811
release_location=asia-south1
release_repository=global
release_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)')
release_active_project=$(gcloud config get-value project)
if [[ "$release_account" != unidevidp@gmail.com || "$release_active_project" != "$release_project" ]]; then
  echo 'Unexpected active GCP identity or project; no IAM changes made.' >&2
  exit 1
fi

printf 'Account: %s\nProject: %s\nRepository: %s/%s\n' \
  "$release_account" "$release_project" "$release_location" "$release_repository"
gcloud artifacts repositories get-iam-policy "$release_repository" \
  --project="$release_project" --location="$release_location" --format=json

for release_reader in \
  kargo-controller@tesseracthub-480811.iam.gserviceaccount.com \
  849928263410-compute@developer.gserviceaccount.com; do
  printf 'Repository reader: %s\n' "$release_reader"
  if [[ "$release_action" == --apply ]]; then
    gcloud artifacts repositories add-iam-policy-binding "$release_repository" \
      --project="$release_project" --location="$release_location" \
      --member="serviceAccount:$release_reader" \
      --role=roles/artifactregistry.reader --condition=None
  fi
done
