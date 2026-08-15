#!/bin/bash
# Behaviour tests for the openpanel clickhouse-disk-guard CronJob script.
# Renders the chart, extracts the script, runs it against a stubbed
# clickhouse-client. Usage: tests/test_clickhouse_disk_guard.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/thirdparty/openpanel"
export WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm template openpanel "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prod.yaml" \
  | python3 -c "
import yaml, sys, os
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'CronJob' and 'disk-guard' in doc['metadata']['name']:
        open(os.path.join(os.environ['WORK'], 'guard.sh'), 'w').write(
            doc['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['command'][2])
        break
else:
    sys.exit('disk-guard CronJob not found in rendered chart')
" || exit 1

mkdir -p "$WORK/bin"
cat > "$WORK/bin/clickhouse-client" <<'STUB'
#!/bin/bash
q=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "CALL: $q" >> "$STUB_DIR/calls.log"
if [[ "$q" == *"system.disks"* ]]; then
  n=$(head -1 "$STUB_DIR/usage")
  if [ "$(wc -l < "$STUB_DIR/usage")" -gt 1 ]; then
    tail -n +2 "$STUB_DIR/usage" > "$STUB_DIR/usage.tmp" && mv "$STUB_DIR/usage.tmp" "$STUB_DIR/usage"
  fi
  echo "$n"; exit 0
fi
[[ "$q" == *"FROM system.parts"* ]] && { cat "$STUB_DIR/tables"; exit 0; }
if [[ "$q" == TRUNCATE* ]]; then
  tbl="${q##*system.}"
  grep -qx "$tbl" "$STUB_DIR/truncate_fails" 2>/dev/null && { echo "Code: 243 NOT_ENOUGH_SPACE" >&2; exit 243; }
fi
exit 0
STUB
chmod +x "$WORK/bin/clickhouse-client"

pass=0; fail=0

setup() {
  export STUB_DIR="$WORK/case"
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
  printf '%s\n' "$1" > "$STUB_DIR/usage"
  printf '%s\n' "$2" > "$STUB_DIR/tables"
  printf '%s\n' "${3:-}" > "$STUB_DIR/truncate_fails"
  : > "$STUB_DIR/calls.log"
  PATH="$WORK/bin:$PATH" CH_HOST=stub CH_PORT=9000 THRESHOLD=90 \
    bash "$WORK/guard.sh" > "$STUB_DIR/out" 2>&1
}

check() {  # name expected has|no file
  if grep -qF "$2" "$STUB_DIR/$4"; then found=yes; else found=no; fi
  if { [ "$3" = has ] && [ $found = yes ]; } || { [ "$3" = no ] && [ $found = no ]; }; then
    echo "  PASS $1"; pass=$((pass+1))
  else
    echo "  FAIL $1 ($3: $2)"; fail=$((fail+1))
  fi
}

echo "below threshold does nothing"
setup "24" "trace_log_0"
check "reports below threshold" "below threshold, nothing to do" has out
check "issues no DROP" "DROP" no calls.log
check "issues no TRUNCATE" "TRUNCATE" no calls.log

echo "orphaned _N table is dropped, not truncated"
setup $'95\n95\n24' "trace_log_0"
check "drops orphan" "DROP TABLE IF EXISTS system.trace_log_0 SYNC" has calls.log
check "does not truncate orphan" "TRUNCATE TABLE IF EXISTS system.trace_log_0" no calls.log

echo "live table falls back to DROP when TRUNCATE cannot reserve space"
setup $'95\n95\n24' "query_log" "query_log"
check "attempts truncate first" "TRUNCATE TABLE IF EXISTS system.query_log" has calls.log
check "falls back to drop" "DROP TABLE IF EXISTS system.query_log SYNC" has calls.log
check "logs the fallback" "truncate failed, dropping system.query_log" has out

echo "live table that truncates cleanly is not dropped"
setup $'95\n95\n24' "query_log"
check "truncates" "TRUNCATE TABLE IF EXISTS system.query_log" has calls.log
check "no drop" "DROP" no calls.log

echo "stops as soon as usage recovers"
setup $'95\n95\n24' $'trace_log_0\ntext_log_0'
check "clears first table" "DROP TABLE IF EXISTS system.trace_log_0 SYNC" has calls.log
check "leaves second table" "DROP TABLE IF EXISTS system.text_log_0 SYNC" no calls.log
check "reports recovery" "recovered to 24%, stopping" has out

echo "warns when still full after clearing everything"
setup "95" "trace_log_0"
check "warns" "still at or above threshold" has out

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
