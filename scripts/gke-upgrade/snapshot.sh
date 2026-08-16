#!/usr/bin/env bash
# Captures cluster health so the post-upgrade check can tell new breakage from old.
# Usage: snapshot.sh <cluster> <region> <project> <out-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

CLUSTER=${1:?cluster}
REGION=${2:?region}
PROJECT=${3:?project}
OUT=${4:?out dir}

mkdir -p "$OUT"
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1

gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format=json >"$OUT/cluster.json"

# Every pool spec verbatim — this is what a recreate is rebuilt from, and the only
# way back if a delete goes wrong.
mkdir -p "$OUT/node-pools"
jq -r '.nodePools[].name' "$OUT/cluster.json" | while read -r pool; do
  gcloud container node-pools describe "$pool" --cluster "$CLUSTER" --region "$REGION" \
    --project "$PROJECT" --format=json >"$OUT/node-pools/${pool}.json"
done

kubectl get nodes -o wide >"$OUT/nodes.txt" 2>&1 || true

# Workloads whose ready replicas are short of desired.
kubectl get deploy,statefulset -A -o json 2>/dev/null | jq -r '
  .items[]
  | select((.spec.replicas // 0) > 0)
  | select((.status.readyReplicas // 0) < (.spec.replicas // 0))
  | "\(.metadata.namespace)/\(.kind|ascii_downcase)/\(.metadata.name)"
' | sort -u >"$OUT/unhealthy-workloads.txt" || true

kubectl get ds -A -o json 2>/dev/null | jq -r '
  .items[]
  | select((.status.numberReady // 0) < (.status.desiredNumberScheduled // 0))
  | "\(.metadata.namespace)/daemonset/\(.metadata.name)"
' | sort -u >>"$OUT/unhealthy-workloads.txt" || true
sort -u -o "$OUT/unhealthy-workloads.txt" "$OUT/unhealthy-workloads.txt"

# Pods that are neither running nor finished cleanly.
kubectl get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase != "Running" and .status.phase != "Succeeded")
  | "\(.metadata.namespace)/\(.metadata.name)"
' | sort -u >"$OUT/unhealthy-pods.txt" || true

kubectl get cluster.postgresql.cnpg.io -A -o json 2>/dev/null | jq -r '
  .items[] | select(.status.phase != "Cluster in healthy state")
  | "\(.metadata.namespace)/\(.metadata.name)"
' | sort -u >"$OUT/unhealthy-cnpg.txt" || true

kubectl get applications.argoproj.io -n argocd -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
  | "\(.metadata.name)"
' | sort -u >"$OUT/unhealthy-argocd.txt" || true

for f in unhealthy-workloads unhealthy-pods unhealthy-cnpg unhealthy-argocd; do
  touch "$OUT/${f}.txt"
  log "snapshot: $(wc -l <"$OUT/${f}.txt" | tr -d ' ') entries in ${f}"
done
