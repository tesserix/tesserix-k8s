#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'container clusters describe '*)
    echo '{"status":"RUNNING","name":"test-cluster","currentMasterVersion":"1.36.4-gke.1391000","releaseChannel":{"channel":"RAPID"},"nodePools":[]}' ;;
  'container get-server-config '*) echo '1.37.0-gke.3503000' ;;
  'container operations list '*)
    if [[ "$*" == *'--format=json'* ]]; then
      if [[ "${ACTIVE_OPERATION:-}" == 'node-pool' ]]; then
        echo '[{"name":"active-node-upgrade","status":"RUNNING","operationType":"UPGRADE_NODES","targetLink":"https://container.googleapis.com/v1/projects/test-project/locations/asia-south1/clusters/test-cluster/nodePools/workers"}]'
      else
        echo '[]'
      fi
    fi ;;
  'recommender insights list '*|'container clusters get-credentials '*) ;;
  *) echo "Unexpected gcloud call: $*" >&2; exit 1 ;;
esac
STUB

cat >"$TEST_DIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'get nodes '*) echo 'test-node Ready worker 1d v1.36.4-gke.1391000' ;;
  'get pdb '*) echo 'database/postgres-primary' ;;
  'get cluster.postgresql.cnpg.io -A -o jsonpath='*) echo 'database/postgres' ;;
  'get '*' -o json') echo '{"items":[]}' ;;
  *) echo "Unexpected kubectl call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
export ALLOW_BLOCKING_PDBS=false ALLOW_OUT_OF_CHANNEL=false

if ! bash "$HERE/../preflight.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 control-plane "$TEST_DIR/control-plane" >"$TEST_DIR/control-plane.log" 2>&1; then
  cat "$TEST_DIR/control-plane.log"
  echo 'FAIL: a control-plane-only upgrade must not be blocked by node eviction budgets' >&2
  exit 1
fi
echo 'PASS: control-plane upgrade reports PDBs without requiring an eviction override'

if bash "$HERE/../preflight.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 node-pools "$TEST_DIR/nodes" >"$TEST_DIR/nodes.log" 2>&1; then
  echo 'FAIL: node upgrades must still reject blocking PDBs' >&2
  exit 1
fi
grep -q 'PDBs allow zero evictions' "$TEST_DIR/nodes.log"
echo 'PASS: node upgrade rejects blocking PDBs'

if ACTIVE_OPERATION=node-pool bash "$HERE/../preflight.sh" test-cluster asia-south1 test-project \
  1.37.0-gke.3503000 control-plane "$TEST_DIR/busy" >"$TEST_DIR/busy.log" 2>&1; then
  echo 'FAIL: active node-pool operations must block a control-plane upgrade' >&2
  exit 1
fi
grep -q 'operations already running: active-node-upgrade' "$TEST_DIR/busy.log"
echo 'PASS: an active node-pool operation blocks a competing upgrade'
