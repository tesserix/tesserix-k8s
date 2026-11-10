#!/usr/bin/env bash
# Performs the upgrade. Preflight must have passed first.
# Usage: upgrade.sh <cluster> <region> <project> <target-version> <scope> <artifacts-dir>
#   scope: control-plane | node-pools | both
# Env: DRY_RUN, POOL_STRATEGY (surge|recreate|skip), RECREATE_POOLS, ONLY_POOL
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
ARTIFACTS=${6:-./upgrade-artifacts}

DRY_RUN=${DRY_RUN:-true}
POOL_STRATEGY=${POOL_STRATEGY:-surge}
RECREATE_POOLS=${RECREATE_POOLS:-}
ONLY_POOL=${ONLY_POOL:-}
OPERATION_MAX_POLLS=${OPERATION_MAX_POLLS:-720}
OPERATION_POLL_SECONDS=${OPERATION_POLL_SECONDS:-20}

[[ "$OPERATION_MAX_POLLS" =~ ^[1-9][0-9]*$ && "$OPERATION_POLL_SECONDS" =~ ^[0-9]+$ ]] ||
  { die "operation polling must use bounded numeric settings"; exit 1; }

case "$DRY_RUN" in
  true|false) ;;
  *) die "DRY_RUN must be true or false"; exit 1 ;;
esac

GC=(gcloud container --project "$PROJECT")

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  DRY-RUN  %s\n' "$*" >&2
    return 0
  fi
  log "running: $*"
  "$@"
}

wait_for_operation() {
  local operation=$1 result status attempt
  for ((attempt=0; attempt<OPERATION_MAX_POLLS; attempt++)); do
    result=$("${GC[@]}" operations describe "$operation" --region "$REGION" --format=json) || return 1
    status=$(jq -r '.status // ""' <<<"$result") || return 1
    case "$status" in
      DONE)
        if jq -e '(.error.code // 0) != 0 or (.error.message // "") != ""' <<<"$result" >/dev/null; then
          die "operation $operation failed: $(jq -r '.error.message // "unknown provider error"' <<<"$result")"
          return 1
        fi
        return 0 ;;
      RUNNING|PENDING) ;;
      *) die "cannot determine operation $operation status"; return 1 ;;
    esac
    sleep "$OPERATION_POLL_SECONDS"
  done
  die "operation $operation is still running; monitor this operation before another upgrade"
  return 1
}

discover_operation() {
  local started=$1 suffix=$2 kind=$3 result count attempt
  for ((attempt=0; attempt<5; attempt++)); do
    result=$("${GC[@]}" operations list --region "$REGION" \
      --filter="startTime>='$started' AND operationType='$kind'" --format=json) || return 1
    result=$(jq --arg suffix "$suffix" '[.[] | select((.targetLink // "") | endswith($suffix))]' <<<"$result") || return 1
    count=$(jq 'length' <<<"$result") || return 1
    if [[ "$count" == 1 ]]; then
      jq -r '.[0].name // ""' <<<"$result"
      return 0
    fi
    if [[ "$count" != 0 ]]; then
      die "more than one matching upgrade operation; inspect GKE before retrying"
      return 1
    fi
    sleep "$OPERATION_POLL_SECONDS"
  done
  die "no matching upgrade operation found; inspect GKE before retrying"
  return 1
}

run_upgrade() {
  local operation started suffix kind arg
  if [[ "$DRY_RUN" == "true" ]]; then
    run "${GC[@]}" clusters upgrade "$CLUSTER" --region "$REGION" "$@" \
      --cluster-version="$TARGET" --quiet --async --format='value(name)'
    return 0
  fi
  started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  suffix="/clusters/$CLUSTER"
  kind=UPGRADE_MASTER
  for arg in "$@"; do
    if [[ "$arg" == --node-pool=* ]]; then
      suffix+="/nodePools/${arg#--node-pool=}"
      kind=UPGRADE_NODES
    fi
  done
  operation=$(run "${GC[@]}" clusters upgrade "$CLUSTER" --region "$REGION" "$@" \
    --cluster-version="$TARGET" --quiet --async --format='value(name)') || return 1
  # The GA SDK submits async upgrades without returning a resource.
  if [[ -z "$operation" ]]; then
    operation=$(discover_operation "$started" "$suffix" "$kind") || return 1
  fi
  [[ "$operation" =~ ^operation-[a-zA-Z0-9-]+$ ]] ||
    { die "upgrade did not return a valid operation ID; inspect GKE before retrying"; return 1; }
  log "waiting for operation $operation"
  wait_for_operation "$operation"
}

upgrade_control_plane() {
  local current
  current=$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    --format='value(currentMasterVersion)')
  if [[ "$current" == "$TARGET" ]]; then
    log "control plane already at $TARGET, nothing to do"
    summary "- Control plane already at \`$TARGET\`"
    return 0
  fi
  log "upgrading control plane $current -> $TARGET (10-20 min, API server briefly unavailable)"
  run_upgrade --master
  summary "- Control plane \`$current\` → \`$TARGET\`"
}

# Surge upgrade in place. Safe when the pool can borrow capacity for an extra node.
upgrade_pool_surge() {
  local pool=$1 current mismatch
  current=$(gcloud container node-pools describe "$pool" --cluster "$CLUSTER" --region "$REGION" \
    --project "$PROJECT" --format='value(version)') || return 1
  if [[ "$current" == "$TARGET" ]]; then
    mismatch=$(kubectl get nodes -l "cloud.google.com/gke-nodepool=$pool" -o json |
      jq -r --arg target "$TARGET" '.items[] | select((.status.nodeInfo.kubeletVersion | ltrimstr("v")) != $target) | .metadata.name') || return 1
    if [[ -z "$mismatch" ]]; then
      log "node pool $pool and its kubelets already at $TARGET, nothing to do"
      summary "- Node pool \`$pool\` already at \`$TARGET\`; no upgrade reissued"
      return 0
    fi
  fi
  log "surge-upgrading node pool $pool -> $TARGET"
  run_upgrade --node-pool="$pool"
  summary "- Node pool \`$pool\` surge-upgraded to \`$TARGET\`"
}

# Delete and rebuild from the captured spec. Used where a surge upgrade would have
# to obtain an extra spot/GPU node that may simply not be available.
recreate_pool() {
  local pool=$1
  local spec="$ARTIFACTS/before/node-pools/${pool}.json"
  [[ -f "$spec" ]] || { die "no captured spec for $pool at $spec — refusing to delete a pool I cannot rebuild"; return 1; }

  local -a flags
  mapfile -t flags < <(pool_create_flags "$(cat "$spec")") ||
    { die "cannot derive create flags for $pool — refusing to delete it"; return 1; }
  ((${#flags[@]} > 0)) || { die "empty create flags for $pool — refusing to delete it"; return 1; }

  local recovery="$ARTIFACTS/recreate-${pool}.sh"
  {
    echo "#!/usr/bin/env bash"
    echo "# Recreates $pool as it existed before the upgrade. Run this if the workflow died mid-recreate."
    echo "set -euo pipefail"
    printf 'gcloud container node-pools create %q \\\n' "$pool"
    printf '  --cluster=%q --region=%q --project=%q \\\n' "$CLUSTER" "$REGION" "$PROJECT"
    printf '  --node-version=%q \\\n' "$TARGET"
    printf '  %q \\\n' "${flags[@]}"
    echo '  --quiet'
  } >"$recovery"
  chmod +x "$recovery"
  log "recovery script written to $recovery"

  log "deleting node pool $pool (workloads on it will be evicted)"
  run "${GC[@]}" node-pools delete "$pool" --cluster "$CLUSTER" --region "$REGION" --quiet

  log "recreating node pool $pool at $TARGET"
  run "${GC[@]}" node-pools create "$pool" --cluster "$CLUSTER" --region "$REGION" \
    --node-version="$TARGET" "${flags[@]}" --quiet

  summary "- Node pool \`$pool\` deleted and recreated at \`$TARGET\` (spec restored from snapshot)"
}

pool_strategy_for() {
  local pool=$1
  if [[ ",${RECREATE_POOLS}," == *",${pool},"* ]]; then
    echo "$POOL_STRATEGY"
  else
    echo "surge"
  fi
}

upgrade_node_pools() {
  local pools
  pools=$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    --format='value(nodePools[].name)' | tr ';' '\n')

  # Recreate-strategy pools go last: they are the ones most likely to stall on capacity,
  # and a failure there should not leave the rest of the cluster half-upgraded.
  local ordered=()
  local pool
  for pool in $pools; do [[ "$(pool_strategy_for "$pool")" == "surge" ]] && ordered+=("$pool"); done
  for pool in $pools; do [[ "$(pool_strategy_for "$pool")" != "surge" ]] && ordered+=("$pool"); done

  for pool in "${ordered[@]}"; do
    if [[ -n "$ONLY_POOL" && "$pool" != "$ONLY_POOL" ]]; then
      log "skipping $pool (only_pool=$ONLY_POOL)"
      continue
    fi
    local strategy
    strategy=$(pool_strategy_for "$pool")
    case "$strategy" in
      surge)    upgrade_pool_surge "$pool" ;;
      recreate) recreate_pool "$pool" ;;
      skip)     log "skipping $pool (strategy=skip)"; summary "- Node pool \`$pool\` **skipped**" ;;
      *)        die "unknown pool strategy: $strategy"; return 1 ;;
    esac
  done
}

summary ""
summary "## Upgrade actions"
summary ""
[[ "$DRY_RUN" == "true" ]] && summary "> **Dry run** — no changes were made."

case "$SCOPE" in
  control-plane) upgrade_control_plane ;;
  node-pools)    upgrade_node_pools ;;
  both)          upgrade_control_plane; upgrade_node_pools ;;
  *)             die "unknown scope: $SCOPE"; exit 1 ;;
esac

log "upgrade actions complete"
