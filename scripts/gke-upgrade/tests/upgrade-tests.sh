#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
export CALL_LOG="$TEST_DIR/mutations.log"
touch "$CALL_LOG"

cat >"$TEST_DIR/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'--format=value(currentMasterVersion)'*) echo '1.36.4-gke.1391000' ;;
  *'--format=value(nodePools[].name)'*) echo 'gpu-l4-spot' ;;
  *) printf '%s\n' "$*" >>"$CALL_LOG" ;;
esac
STUB
chmod +x "$TEST_DIR/bin/gcloud"
export PATH="$TEST_DIR/bin:$PATH"
unset DRY_RUN POOL_STRATEGY RECREATE_POOLS ONLY_POOL

bash "$HERE/../upgrade.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 control-plane "$TEST_DIR" >"$TEST_DIR/control-plane.log" 2>&1
if [[ -s "$CALL_LOG" ]]; then
  echo 'FAIL: an invocation without DRY_RUN=false must not mutate GKE' >&2
  exit 1
fi
grep -q 'DRY-RUN' "$TEST_DIR/control-plane.log"
echo 'PASS: upgrade is a dry run by default'

DRY_RUN=true bash "$HERE/../upgrade.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 node-pools "$TEST_DIR" >"$TEST_DIR/nodes.log" 2>&1
grep -q 'surge-upgrading node pool gpu-l4-spot' "$TEST_DIR/nodes.log"
if grep -q 'deleting node pool' "$TEST_DIR/nodes.log"; then
  echo 'FAIL: default node upgrade must not delete pools' >&2
  exit 1
fi
echo 'PASS: default node upgrade uses surge without deleting pools'

if DRY_RUN=typo bash "$HERE/../upgrade.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 control-plane "$TEST_DIR" >"$TEST_DIR/invalid.log" 2>&1; then
  echo 'FAIL: invalid DRY_RUN must be rejected rather than interpreted as permission to mutate' >&2
  exit 1
fi
[[ ! -s "$CALL_LOG" ]]
echo 'PASS: invalid DRY_RUN cannot authorize mutation'
