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

DRY_RUN=${DRY_RUN:-false}
POOL_STRATEGY=${POOL_STRATEGY:-recreate}
RECREATE_POOLS=${RECREATE_POOLS:-gpu-l4-spot}
ONLY_POOL=${ONLY_POOL:-}

GC=(gcloud container --project "$PROJECT")

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  DRY-RUN  %s\n' "$*" >&2
    return 0
  fi
  log "running: $*"
  "$@"
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
  run "${GC[@]}" clusters upgrade "$CLUSTER" --region "$REGION" --master \
    --cluster-version="$TARGET" --quiet
  summary "- Control plane \`$current\` → \`$TARGET\`"
}

# Surge upgrade in place. Safe when the pool can borrow capacity for an extra node.
upgrade_pool_surge() {
  local pool=$1
  log "surge-upgrading node pool $pool -> $TARGET"
  run "${GC[@]}" clusters upgrade "$CLUSTER" --region "$REGION" --node-pool="$pool" \
    --cluster-version="$TARGET" --quiet
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
