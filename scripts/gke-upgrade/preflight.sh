#!/usr/bin/env bash
# Read-only gate for a GKE upgrade. Non-zero exit means do not proceed.
# Usage: preflight.sh <cluster> <region> <project> <target-version> <scope> [out-dir]
# The reporters below always succeed, so `cond && pass || block` is a real if-then-else.
# shellcheck disable=SC2015
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

CLUSTER=${1:?cluster}
REGION=${2:?region}
PROJECT=${3:?project}
TARGET=${4:?target version}
SCOPE=${5:-both}
OUT=${6:-./upgrade-artifacts}

ALLOW_BLOCKING_PDBS=${ALLOW_BLOCKING_PDBS:-false}
ALLOW_OUT_OF_CHANNEL=${ALLOW_OUT_OF_CHANNEL:-false}

mkdir -p "$OUT"
BLOCKERS=()
block() { BLOCKERS+=("$1"); printf '  BLOCKED  %s\n' "$1" >&2; }
pass()  { printf '  ok       %s\n' "$1" >&2; }

log "preflight: $CLUSTER ($REGION) -> $TARGET, scope=$SCOPE"

CLUSTER_JSON=$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format=json)
echo "$CLUSTER_JSON" >"$OUT/cluster-before.json"

CP_VERSION=$(jq -r '.currentMasterVersion' <<<"$CLUSTER_JSON")
CHANNEL=$(jq -r '.releaseChannel.channel // "UNSPECIFIED"' <<<"$CLUSTER_JSON")
STATUS=$(jq -r '.status' <<<"$CLUSTER_JSON")

echo "cluster status"
[[ "$STATUS" == "RUNNING" ]] && pass "cluster is RUNNING" || block "cluster status is $STATUS, not RUNNING"

echo "in-flight operations"
RUNNING_OPS=$(gcloud container operations list --region "$REGION" --project "$PROJECT" \
  --filter="status=RUNNING AND targetLink~${CLUSTER}$" --format="value(name,operationType)" 2>/dev/null || true)
[[ -z "$RUNNING_OPS" ]] && pass "no operations in flight" || block "operations already running: $RUNNING_OPS"

echo "version path"
if assert_upgrade_path "$CP_VERSION" "$TARGET" 2>/dev/null; then
  pass "$CP_VERSION -> $TARGET is a legal upgrade path"
else
  block "$(assert_upgrade_path "$CP_VERSION" "$TARGET" 2>&1 | tail -1)"
fi

echo "release channel"
if [[ "$CHANNEL" == "UNSPECIFIED" ]]; then
  pass "cluster is not on a release channel"
else
  VALID=$(gcloud container get-server-config --region "$REGION" --project "$PROJECT" \
    --flatten="channels" --filter="channels.channel=$CHANNEL" --format="value(channels.validVersions)" 2>/dev/null | tr ';' '\n')
  if grep -qxF "$TARGET" <<<"$VALID"; then
    pass "$TARGET is offered on the $CHANNEL channel"
  elif [[ "$ALLOW_OUT_OF_CHANNEL" == "true" ]]; then
    warn "$TARGET is NOT offered on $CHANNEL — proceeding because allow_out_of_channel=true"
  else
    block "$TARGET is not a valid version for the $CHANNEL channel (set allow_out_of_channel to override)"
  fi
fi

echo "node pool versions"
while read -r name version; do
  [[ -z "$name" ]] && continue
  if assert_node_not_ahead_of_control_plane "$version" "$TARGET" 2>/dev/null; then
    pass "node pool $name at $version"
  else
    block "node pool $name at $version would be ahead of target control plane $TARGET"
  fi
done < <(jq -r '.nodePools[] | "\(.name) \(.version)"' <<<"$CLUSTER_JSON")

echo "maintenance exclusions"
EXCLUSIONS=$(jq -r '.maintenancePolicy.window.maintenanceExclusions // {} | keys[]' <<<"$CLUSTER_JSON" 2>/dev/null || true)
[[ -z "$EXCLUSIONS" ]] && pass "no maintenance exclusions set" || warn "maintenance exclusions present: $(tr '\n' ' ' <<<"$EXCLUSIONS")"

echo "deprecated api usage"
DEPRECATIONS=$(gcloud recommender insights list --project "$PROJECT" --location "$REGION" \
  --insight-type=google.container.DiagnosisInsight --filter="insightSubtype~DEPRECATION" \
  --format="value(insightSubtype)" 2>/dev/null || echo "__UNAVAILABLE__")
if [[ "$DEPRECATIONS" == "__UNAVAILABLE__" ]]; then
  warn "could not read deprecation insights (needs roles/recommender.viewer) — check the console manually"
elif [[ -z "$DEPRECATIONS" ]]; then
  pass "no deprecated API usage reported"
else
  block "cluster uses APIs removed in a later version: $(tr '\n' ' ' <<<"$DEPRECATIONS")"
fi

gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1

echo "node readiness"
NODE_ISSUES=0
while read -r node status; do
  [[ -z "$node" ]] && continue
  case "$(node_status_class "$status")" in
    ok) ;;
    warn) warn "node $node is $status (autoscaler churn, not blocking)"; NODE_ISSUES=$((NODE_ISSUES + 1)) ;;
    block) block "node $node is $status"; NODE_ISSUES=$((NODE_ISSUES + 1)) ;;
  esac
done < <(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1" "$2}')
((NODE_ISSUES == 0)) && pass "all nodes Ready" || true

echo "pod disruption budgets"
BLOCKING_PDBS=$(kubectl get pdb -A \
  -o jsonpath='{range .items[?(@.status.disruptionsAllowed==0)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null |
  grep -v '^[[:space:]]*$' || true)
echo "$BLOCKING_PDBS" >"$OUT/blocking-pdbs.txt"
if [[ -z "$BLOCKING_PDBS" ]]; then
  pass "every PDB allows at least one eviction"
elif [[ "$ALLOW_BLOCKING_PDBS" == "true" ]]; then
  warn "$(wc -l <<<"$BLOCKING_PDBS" | tr -d ' ') PDBs allow zero evictions — proceeding, GKE will force-drain after ~1h per node"
else
  block "$(wc -l <<<"$BLOCKING_PDBS" | tr -d ' ') PDBs allow zero evictions and will stall node drains: $(tr '\n' ' ' <<<"$BLOCKING_PDBS")"
fi

echo "single-instance postgres"
SINGLE_PG=$(kubectl get cluster.postgresql.cnpg.io -A \
  -o jsonpath='{range .items[?(@.spec.instances==1)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null |
  grep -v '^[[:space:]]*$' || true)
[[ -z "$SINGLE_PG" ]] && pass "no single-instance CNPG clusters" ||
  warn "single-instance CNPG clusters take downtime on node drain: $(tr '\n' ' ' <<<"$SINGLE_PG")"

log "capturing pre-upgrade baseline"
"${HERE}/snapshot.sh" "$CLUSTER" "$REGION" "$PROJECT" "$OUT/before"

summary "## GKE upgrade preflight"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Cluster | \`$CLUSTER\` ($REGION) |"
summary "| Control plane | \`$CP_VERSION\` |"
summary "| Target | \`$TARGET\` |"
summary "| Channel | \`$CHANNEL\` |"
summary "| Scope | \`$SCOPE\` |"
summary "| Blockers | ${#BLOCKERS[@]} |"

if ((${#BLOCKERS[@]} > 0)); then
  summary ""
  summary "### Blockers"
  for b in "${BLOCKERS[@]}"; do summary "- $b"; done
  die "preflight failed with ${#BLOCKERS[@]} blocker(s)"
  exit 1
fi

log "preflight passed"
