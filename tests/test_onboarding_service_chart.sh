#!/bin/bash
# The onboarding API holds the iam-admin PAT and can create a tenant in any
# product, so its posture is asserted rather than assumed.
# Usage: tests/test_onboarding_service_chart.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/apps/onboarding-service"

pass=0; fail=0
check() { # check <description> <condition-result>
  if [ "$2" -eq 0 ]; then echo "  PASS $1"; pass=$((pass+1));
  else echo "  FAIL $1"; fail=$((fail+1)); fi
}

# A blank platformOrgId must fail the render, not default to something.
helm template onboarding-service "$CHART" >/dev/null 2>&1
check "a blank zitadel.platformOrgId fails the render" "$([ $? -ne 0 ] && echo 0 || echo 1)"

RENDER=$(helm template onboarding-service "$CHART" --set zitadel.platformOrgId=123456 2>/dev/null)
if [ -z "$RENDER" ]; then
  echo "  FAIL chart does not render with a platformOrgId set"
  echo; echo "passed=$pass failed=1"; exit 1
fi

echo "$RENDER" | grep -q 'name: default-deny'
check "the namespace has a default-deny NetworkPolicy" $?

echo "$RENDER" | grep -q 'port: 15008'
check "ambient HBONE 15008 is open both ways" $?

# The PAT and the database password reach the pod only through the ExternalSecret.
echo "$RENDER" | grep -Eq 'ZITADEL_PAT: "\{\{ \.pat \}\}"'
check "the Zitadel PAT comes from the secret store, not a value" $?

echo "$RENDER" | grep -q 'urlquery'
check "the database password is url-encoded into DATABASE_URL" $?

[ "$(echo "$RENDER" | grep -c 'readOnlyRootFilesystem: true')" -eq 2 ]
check "both workloads run with a read-only root filesystem" $?

[ "$(echo "$RENDER" | grep -c 'runAsNonRoot: true')" -eq 2 ]
check "both workloads run as non-root" $?

echo "$RENDER" | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "VirtualService":
        routes = doc["spec"]["http"]
        api = routes[0]
        prefixes = {m["uri"]["prefix"] for m in api["match"]}
        assert prefixes == {"/api/", "/v1/"}, prefixes
        assert api["route"][0]["destination"]["host"].startswith("onboarding-api."), api
        assert "match" not in routes[-1], "the console must be the catch-all route"
        sys.exit(0)
sys.exit(1)
' 2>/dev/null
check "the gateway sends /api and /v1 to the API and the rest to the console" $?

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
