#!/bin/bash
# OpenPanel rejects an event whose Origin is absent from projects.cors with
# 401 "Invalid cors or secret", so every host a tenant can actually be served
# on must be covered — including slugs onboarded after this chart was applied.
# Usage: tests/test_openpanel_project_cors.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

rendered=$(helm template openpanel "$REPO/charts/thirdparty/openpanel" \
  --values "$REPO/charts/thirdparty/openpanel/values-prod.yaml" 2>/dev/null)

cors_for() {
  printf '%s' "$rendered" | python3 -c '
import sys, yaml
want = sys.argv[1]
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "Job":
        for container in doc["spec"]["template"]["spec"]["containers"]:
            for env in container.get("env", []):
                if env["name"] == want:
                    print(env.get("value", ""))
                    sys.exit(0)
sys.exit(0)
' "$1"
}

pass=0; fail=0

check() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "  PASS $label"; pass=$((pass+1)) ;;
    *) echo "  FAIL $label — got '$haystack'"; fail=$((fail+1)) ;;
  esac
}

refute() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "  FAIL $label — '$needle' still present"; fail=$((fail+1)) ;;
    *) echo "  PASS $label"; pass=$((pass+1)) ;;
  esac
}

admin=$(cors_for APP_ADMIN_CORS)
storefront=$(cors_for APP_STOREFRONT_CORS)
onboarding=$(cors_for APP_TENANT_ONBOARDING_CORS)

# Merchants sign in at {slug}-admin.mark8ly.com, never at the canonical host.
check "admin allows every tenant subdomain" "$admin" "https://*.mark8ly.com"
check "storefront allows every tenant subdomain" "$storefront" "https://*.mark8ly.com"
refute "onboarding drops the retired host" "$onboarding" "onboard-your-store"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
