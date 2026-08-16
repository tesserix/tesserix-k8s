#!/usr/bin/env bash
# Post-upgrade verification. Fails on anything this upgrade broke, ignoring what
# was already broken before it started.
# Usage: verify.sh <cluster> <region> <project> <target-version> <before-dir> <after-dir>
# The reporters below always succeed, so `cond && pass || fail` is a real if-then-else.
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
BEFORE=${5:?before dir}
AFTER=${6:?after dir}

SETTLE_SECONDS=${SETTLE_SECONDS:-180}
EXPECT_NODE_VERSIONS=${EXPECT_NODE_VERSIONS:-true}

FAILURES=()
fail() { FAILURES+=("$1"); printf '  FAILED   %s\n' "$1" >&2; }
pass() { printf '  ok       %s\n' "$1" >&2; }

log "letting workloads settle for ${SETTLE_SECONDS}s before verifying"
sleep "$SETTLE_SECONDS"

"${HERE}/snapshot.sh" "$CLUSTER" "$REGION" "$PROJECT" "$AFTER"

echo "control plane version"
CP=$(jq -r '.currentMasterVersion' "$AFTER/cluster.json")
[[ "$CP" == "$TARGET" ]] && pass "control plane at $TARGET" || fail "control plane is $CP, expected $TARGET"

if [[ "$EXPECT_NODE_VERSIONS" == "true" ]]; then
  echo "node pool versions"
  while read -r name version; do
    [[ "$version" == "$TARGET" ]] && pass "node pool $name at $TARGET" ||
      fail "node pool $name is $version, expected $TARGET"
  done < <(jq -r '.nodePools[] | "\(.name) \(.version)"' "$AFTER/cluster.json")
fi

echo "node readiness"
NOT_READY=""
while read -r node status; do
  [[ -z "$node" ]] && continue
  case "$(node_status_class "$status")" in
    ok) ;;
    warn) warn "node $node is $status (autoscaler churn, not a failure)" ;;
    block) NOT_READY+="$node ($status) "; fail "node $node is $status after the upgrade" ;;
  esac
done < <(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1" "$2}')
[[ -z "$NOT_READY" ]] && pass "all nodes Ready" || true

echo "kubelet versions"
STALE_KUBELET=$(kubectl get nodes -o json 2>/dev/null |
  jq -r --arg t "$TARGET" '.items[] | select((.status.nodeInfo.kubeletVersion | ltrimstr("v")) as $k | ($t | startswith($k)) | not) | .metadata.name' || true)
[[ -z "$STALE_KUBELET" ]] && pass "kubelets match the target version" ||
  warn "kubelet version mismatch on: $(tr '\n' ' ' <<<"$STALE_KUBELET")"

check_delta() {
  local label=$1 file=$2
  local delta
  delta=$(unhealthy_delta "$(cat "$BEFORE/$file" 2>/dev/null || true)" "$(cat "$AFTER/$file" 2>/dev/null || true)")
  if [[ -z "$delta" ]]; then
    pass "no new $label broken by the upgrade"
  else
    fail "$label newly unhealthy: $(tr '\n' ' ' <<<"$delta")"
  fi
}

echo "workload health versus baseline"
check_delta "workloads" unhealthy-workloads.txt
check_delta "pods" unhealthy-pods.txt
check_delta "CNPG clusters" unhealthy-cnpg.txt
check_delta "ArgoCD applications" unhealthy-argocd.txt

echo "rollout completion"
STUCK=$(kubectl get deploy,statefulset,ds -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.metadata.annotations["deployment.kubernetes.io/revision"] != null or .kind != "Deployment")
  | select(
      (.kind == "Deployment"  and (.status.unavailableReplicas // 0) > 0) or
      (.kind == "StatefulSet" and ((.status.readyReplicas // 0) < (.spec.replicas // 0))) or
      (.kind == "DaemonSet"   and ((.status.numberUnavailable // 0) > 0))
    )
  | "\(.metadata.namespace)/\(.kind|ascii_downcase)/\(.metadata.name)"' | sort -u || true)
NEW_STUCK=$(unhealthy_delta "$(cat "$BEFORE/unhealthy-workloads.txt" 2>/dev/null || true)" "$STUCK")
[[ -z "$NEW_STUCK" ]] && pass "no rollouts left incomplete" ||
  fail "rollouts incomplete: $(tr '\n' ' ' <<<"$NEW_STUCK")"

summary ""
summary "## Post-upgrade verification"
summary ""
summary "| Check | Result |"
summary "|---|---|"
summary "| Control plane | \`$CP\` |"
summary "| Nodes Ready | $([[ -z "$NOT_READY" ]] && echo 'all' || echo "$NOT_READY") |"
summary "| New unhealthy workloads | $(unhealthy_delta "$(cat "$BEFORE/unhealthy-workloads.txt" 2>/dev/null || true)" "$(cat "$AFTER/unhealthy-workloads.txt" 2>/dev/null || true)" | grep -c . || true) |"
summary "| New unhealthy pods | $(unhealthy_delta "$(cat "$BEFORE/unhealthy-pods.txt" 2>/dev/null || true)" "$(cat "$AFTER/unhealthy-pods.txt" 2>/dev/null || true)" | grep -c . || true) |"
summary "| Failures | ${#FAILURES[@]} |"

if ((${#FAILURES[@]} > 0)); then
  summary ""
  summary "### Failures"
  for f in "${FAILURES[@]}"; do summary "- $f"; done
  die "verification failed with ${#FAILURES[@]} failure(s)"
  exit 1
fi

log "verification passed"
