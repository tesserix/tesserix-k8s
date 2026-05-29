#!/usr/bin/env bash
# install-devai-local.sh — deploy DevAI onto the local kind cluster using the
# per-chart `values-local.yaml` overlays (Flow B in LOCAL-SETUP.md).
#
# Idempotent: safe to re-run. Decoupled from GKE prod (local Secrets, local
# images, no Workload Identity, neutralised prod URLs).
#
# Prereqs:
#   - `sandboxctl up` already ran (kind cluster `sandboxctl` exists).
#   - devai/k8s/secrets.yaml exists (cp from k8s/secrets.example.yaml + fill in).
#
# Usage:
#   tesserix-k8s/local/install-devai-local.sh            # build images + deploy all
#   SKIP_BUILD=1 tesserix-k8s/local/install-devai-local.sh   # reuse loaded images
#   ONLY=api tesserix-k8s/local/install-devai-local.sh   # api only (skip dashboards/sre/bff)
set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-sandboxctl}"
NS="${NS:-devai}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$SCRIPT_DIR/../charts/apps"                 # tesserix-k8s/charts/apps
DEVAI="$(cd "$SCRIPT_DIR/../../devai" && pwd)"    # the devai product repo
SCHEMA="$K8S/db-schema-bootstrap/schemas/devai/devai_db/devai.sql"

say() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }

[[ -f "$DEVAI/k8s/secrets.yaml" ]] || {
  echo "ERROR: $DEVAI/k8s/secrets.yaml not found."
  echo "       cp $DEVAI/k8s/secrets.example.yaml $DEVAI/k8s/secrets.yaml and fill it in."
  exit 1
}

say "Namespace + secrets"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" apply -f "$DEVAI/k8s/secrets.yaml"

build_load() {  # build_load <image> <dockerfile> <context>
  local img="$1" df="$2" ctx="$3"
  say "build $img:local"
  docker build -t "$img:local" -f "$DEVAI/$df" "$DEVAI/$ctx"
  kind load docker-image "$img:local" --name "$KIND_CLUSTER"
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  build_load devai-api Dockerfile .
  if [[ "${ONLY:-all}" == "all" ]]; then
    build_load devai-sre           Dockerfile.sre              .
    build_load devai-dashboard     dashboard/Dockerfile        dashboard
    build_load devai-sre-dashboard sre-dashboard/Dockerfile    sre-dashboard
    build_load devai-auth-bff      services/auth-bff/Dockerfile services/auth-bff
  fi
fi

say "Datastores: SHARED local-infra (CNPG Postgres + Redis + NATS + Mongo)"
# DevAI no longer runs its own Postgres/Redis. The shared local-infra chart
# (charts/apps/local-infra) provides them and creates an empty devai_db. Ensure
# it's deployed first — see tesserix-k8s/local/LOCAL-SETUP.md.
if ! kubectl -n local-infra get cluster local-pg >/dev/null 2>&1; then
  echo "ERROR: shared local-infra not found (no CNPG cluster local-pg in ns local-infra)."
  echo "       Deploy it first:  charts/apps/local-root/apply-local.sh   (or sandboxctl deploy --chart charts/apps/local-infra --name local-infra --no-build)"
  exit 1
fi

say "DevAI Postgres schema (into shared devai_db)"
kubectl -n "$NS" create configmap devai-schema \
  --from-file=devai.sql="$SCHEMA" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" delete job devai-schema-bootstrap --ignore-not-found
kubectl -n "$NS" apply -f "$SCRIPT_DIR/devai/schema-bootstrap.job.yaml"
kubectl -n "$NS" wait --for=condition=complete job/devai-schema-bootstrap --timeout=180s

say "Charts"
helm upgrade --install devai-api "$K8S/devai-api" -n "$NS" -f "$K8S/devai-api/values-local.yaml"
if [[ "${ONLY:-all}" == "all" ]]; then
  helm upgrade --install devai-sre           "$K8S/devai-sre"           -n "$NS" -f "$K8S/devai-sre/values-local.yaml"
  helm upgrade --install devai-dashboard     "$K8S/devai-dashboard"     -n "$NS" -f "$K8S/devai-dashboard/values-local.yaml"
  helm upgrade --install devai-sre-dashboard "$K8S/devai-sre-dashboard" -n "$NS" -f "$K8S/devai-sre-dashboard/values-local.yaml"
  helm upgrade --install devai-auth-bff      "$K8S/devai-auth-bff"      -n "$NS" -f "$K8S/devai-auth-bff/values-local.yaml"
fi

say "Done. Port-forward to use:"
echo "  kubectl -n $NS port-forward svc/devai-api 8080:8080"
echo "  kubectl -n $NS port-forward svc/devai-dashboard 3100:3100"
