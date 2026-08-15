#!/bin/bash
# No wildcard can cover a merchant's own domain, so verified custom domains have
# to be reconciled into the storefront project's cors list or those merchants
# collect nothing. Usage: tests/test_openpanel_cors_sync.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

rendered=$(helm template openpanel "$REPO/charts/thirdparty/openpanel" \
  --values "$REPO/charts/thirdparty/openpanel/values-prod.yaml" 2>/dev/null)

doc() {
  printf '%s' "$rendered" | python3 -c '
import sys, yaml
kind, name = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == kind and d.get("metadata", {}).get("name") == name:
        yaml.safe_dump(d, sys.stdout)
        break
' "$1" "$2"
}

pass=0; fail=0

check() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "  PASS $label"; pass=$((pass+1)) ;;
    *) echo "  FAIL $label"; fail=$((fail+1)) ;;
  esac
}

cronjob=$(doc CronJob openpanel-cors-sync)
hook=$(doc Job openpanel-cors-sync)

check "cors-sync CronJob is rendered" "$cronjob" "kind: CronJob"
# The AuthorizationPolicy on marketplace-api-admin matches on SPIFFE identity,
# which the pod only carries if it runs as the chart's own service account.
check "runs under the openpanel service account" "$cronjob" "serviceAccountName: openpanel"
check "authenticates to marketplace-api" "$cronjob" "X-Internal-Auth"
check "reads the active-domains endpoint" "$cronjob" "/internal/active-domains"
check "keeps the configured platform origins" "$cronjob" 'https://*.mark8ly.com'
check "targets the storefront project" "$cronjob" "tesserix-storefront"

# project-init reassigns cors wholesale on every sync, so without a PostSync
# twin an ArgoCD sync would drop every custom domain until the next cron tick.
check "PostSync hook twin is rendered" "$hook" "PostSync"
check "hook runs after project-init" "$hook" "sync-wave"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
