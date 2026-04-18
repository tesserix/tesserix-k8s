#!/usr/bin/env bash
#
# setup-artifact-registry-mirror.sh
#
# Idempotent setup for the Artifact Registry remote repositories that front
# ghcr.io, docker.io, quay.io, and registry.k8s.io for the GKE cluster.
#
# Creating these mirrors keeps image pulls inside asia-south1 (free) instead
# of flowing through Cloud NAT ($0.045/GB). See docs/artifact-registry-mirror.md
# for the full rationale, IAM model, and cost analysis.
#
# Safe to re-run: every mutating call checks for existence first and skips
# if the resource already exists.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tesseracthub-480811}"
PROJECT_NUMBER="${PROJECT_NUMBER:-849928263410}"
LOCATION="${LOCATION:-asia-south1}"

GKE_NODE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
AR_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-artifactregistry.iam.gserviceaccount.com"

GHCR_SECRET="prod-tesserix-ghcr-token"
GHCR_USERNAME="Sam123ben"

say() { printf '\n▸ %s\n' "$*"; }

ensure_api() {
  local api=$1
  if ! gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" | grep -qx "$api"; then
    say "Enabling $api"
    gcloud services enable "$api" --project="$PROJECT_ID"
  fi
}

ensure_secret_access() {
  say "Granting Artifact Registry service agent read access to $GHCR_SECRET"
  gcloud secrets add-iam-policy-binding "$GHCR_SECRET" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${AR_SERVICE_AGENT}" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None >/dev/null
}

repo_exists() {
  gcloud artifacts repositories describe "$1" \
    --project="$PROJECT_ID" --location="$LOCATION" >/dev/null 2>&1
}

create_public_remote() {
  local name=$1 upstream=$2 desc=$3
  if repo_exists "$name"; then
    say "Repo $name already exists — skipping create"
    return
  fi
  say "Creating remote repo $name → $upstream"
  gcloud artifacts repositories create "$name" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --repository-format=docker \
    --mode=remote-repository \
    --description="$desc" \
    --remote-repo-config-desc="$desc" \
    --remote-docker-repo="$upstream"
}

create_ghcr_remote() {
  local name="ghcr-remote"
  if repo_exists "$name"; then
    say "Repo $name already exists — skipping create"
    return
  fi
  say "Creating authenticated remote repo $name → https://ghcr.io"
  gcloud artifacts repositories create "$name" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --repository-format=docker \
    --mode=remote-repository \
    --description="ghcr.io mirror (authenticated via $GHCR_SECRET)" \
    --remote-repo-config-desc="ghcr.io mirror ($GHCR_USERNAME)" \
    --remote-docker-repo="https://ghcr.io" \
    --remote-username="$GHCR_USERNAME" \
    --remote-password-secret-version="projects/${PROJECT_NUMBER}/secrets/${GHCR_SECRET}/versions/latest"
}

grant_node_sa_reader() {
  local repo=$1
  say "Granting artifactregistry.reader on $repo to $GKE_NODE_SA"
  gcloud artifacts repositories add-iam-policy-binding "$repo" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --member="serviceAccount:${GKE_NODE_SA}" \
    --role="roles/artifactregistry.reader" >/dev/null
}

main() {
  ensure_api artifactregistry.googleapis.com
  ensure_api secretmanager.googleapis.com

  ensure_secret_access

  create_public_remote docker-remote DOCKER-HUB            "Public Docker Hub mirror — reduces Cloud NAT egress"
  create_public_remote quay-remote   https://quay.io       "quay.io mirror — reduces Cloud NAT egress"
  create_public_remote k8s-remote    https://registry.k8s.io "registry.k8s.io mirror — reduces Cloud NAT egress"
  create_ghcr_remote

  for repo in docker-remote quay-remote k8s-remote ghcr-remote; do
    grant_node_sa_reader "$repo"
  done

  say "Done. Listing created repositories:"
  gcloud artifacts repositories list \
    --project="$PROJECT_ID" --location="$LOCATION" \
    --format="table(name.basename(),format,mode,description)"
}

main "$@"
