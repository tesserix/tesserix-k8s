#!/bin/bash
# Every instrumented app must point at the self-hosted tracking script. Without
# OPENPANEL_SCRIPT_URL the SDK falls back to openpanel.dev's CDN.
# Usage: tests/test_openpanel_app_env.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; fail=0

for chart in company tesserix-blog; do
  helm dependency build "$REPO/charts/apps/$chart" >/dev/null 2>&1
  url=$(helm template "$chart" "$REPO/charts/apps/$chart" \
    | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "Deployment":
        for container in doc["spec"]["template"]["spec"]["containers"]:
            for env in container.get("env", []):
                if env["name"] == "OPENPANEL_SCRIPT_URL":
                    print(env.get("value", ""))
                    sys.exit(0)
sys.exit(0)
')
  if [ "$url" = "https://analytics.tesserix.app/op1.js" ]; then
    echo "  PASS $chart points at the self-hosted script"; pass=$((pass+1))
  else
    echo "  FAIL $chart OPENPANEL_SCRIPT_URL is '${url}'"; fail=$((fail+1))
  fi
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
