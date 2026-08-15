#!/bin/bash
# A failed reconcile must leave its logs behind. restartPolicy OnFailure deletes
# the pod on each retry, and a 10m TTL removed the job before anyone looked.
# Usage: tests/test_zitadel_bootstrap_diagnosable.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; fail=0

spec=$(helm template zb "$REPO/charts/apps/zitadel-bootstrap" \
  | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "CronJob":
        s = doc["spec"]
        j = s["jobTemplate"]["spec"]
        print(j["template"]["spec"]["restartPolicy"],
              j["ttlSecondsAfterFinished"],
              s.get("failedJobsHistoryLimit", "unset"))
        break
')
read -r policy ttl failed_history <<<"$spec"

if [ "$policy" = "Never" ]; then
  echo "  PASS restartPolicy keeps each failed attempt's pod"; pass=$((pass+1))
else
  echo "  FAIL restartPolicy is '$policy', which discards the pod on retry"; fail=$((fail+1))
fi

# One 30m interval is the floor; a run that fails at 03:00 has to still be there.
if [ "$ttl" -ge 3600 ] 2>/dev/null; then
  echo "  PASS ttlSecondsAfterFinished ($ttl) outlives the schedule"; pass=$((pass+1))
else
  echo "  FAIL ttlSecondsAfterFinished is '$ttl', too short to inspect a failure"; fail=$((fail+1))
fi

if [ "$failed_history" != "unset" ] && [ "$failed_history" -ge 1 ] 2>/dev/null; then
  echo "  PASS failedJobsHistoryLimit is set explicitly ($failed_history)"; pass=$((pass+1))
else
  echo "  FAIL failedJobsHistoryLimit is '$failed_history'"; fail=$((fail+1))
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
