#!/bin/bash
# The onboarding API can create a tenant in any product, so its posture is
# asserted rather than assumed.
# Usage: tests/test_onboarding_service_chart.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/apps/onboarding-service"

pass=0; fail=0
check() { # check <description> <condition-result>
  if [ "$2" -eq 0 ]; then echo "  PASS $1"; pass=$((pass+1));
  else echo "  FAIL $1"; fail=$((fail+1)); fi
}

CONSOLE_ARGS=(--set console.googleClientId=console-app --set 'console.adminEmails={first@example.test,second@example.test}')

# Without the Google client id nobody can sign in, so a blank one fails the
# render instead of shipping a console that silently cannot authenticate.
helm template onboarding-service "$CHART" --set 'console.adminEmails={first@example.test}' >/dev/null 2>&1
check "a blank console.googleClientId fails the render" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# An empty allowlist would be a console with no users; that is a mistake, not a
# configuration.
helm template onboarding-service "$CHART" --set console.googleClientId=console-app >/dev/null 2>&1
check "an empty console.adminEmails fails the render" "$([ $? -ne 0 ] && echo 0 || echo 1)"

RENDER=$(helm template onboarding-service "$CHART" "${CONSOLE_ARGS[@]}" 2>/dev/null)
if [ -z "$RENDER" ]; then
  echo "  FAIL chart does not render with the console settings supplied"
  echo; echo "passed=$pass failed=1"; exit 1
fi

# The allowlist is a chart value, so changing who may sign in is a reviewed PR.
echo "$RENDER" | grep -q 'value: "first@example.test,second@example.test"'
check "the admin allowlist reaches the pod from the chart" $?

echo "$RENDER" | grep -Eq 'GOOGLE_CLIENT_SECRET: "\{\{ \.googleClientSecret \}\}"'
check "the Google client secret comes from the secret store, not a value" $?

# The three addresses prod actually ships with, read from values-prod.yaml.
PROD_RENDER=$(helm template onboarding-service "$CHART" -f "$CHART/values-prod.yaml" 2>/dev/null)
echo "$PROD_RENDER" | grep -q 'value: "samyak.rout@gmail.com,unidevidp@gmail.com,mahesh.sangawar@gmail.com"'
check "prod admits exactly the three platform admins" $?

# The org id is resolved from the name at boot; a hand-copied id goes stale the
# moment the org is recreated.
echo "$RENDER" | grep -q 'name: PLATFORM_ORG_NAME'
check "the platform org is named, not numbered" $?

echo "$RENDER" | grep -q 'name: default-deny'
check "the namespace has a default-deny NetworkPolicy" $?

echo "$RENDER" | grep -q 'port: 15008'
check "ambient HBONE 15008 is open both ways" $?

# The Zitadel credential and the database password reach the pod only through
# the ExternalSecret, and the default credential is the scoped machine key.
echo "$RENDER" | grep -Eq 'ZITADEL_MACHINE_KEY: "\{\{ \.machineKey \}\}"'
check "the Zitadel machine key comes from the secret store, not a value" $?

echo "$RENDER" | grep -q 'ZITADEL_PAT'
check "the instance-wide PAT is not mounted by default" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# The PAT is break-glass: reachable, but only by asking for it.
PAT_RENDER=$(helm template onboarding-service "$CHART" \
  "${CONSOLE_ARGS[@]}" --set externalSecret.credential=pat 2>/dev/null)
echo "$PAT_RENDER" | grep -Eq 'ZITADEL_PAT: "\{\{ \.pat \}\}"'
check "the break-glass PAT is available on request" $?

echo "$PAT_RENDER" | grep -q 'ZITADEL_MACHINE_KEY'
check "the two credentials are never mounted together" "$([ $? -ne 0 ] && echo 0 || echo 1)"

helm template onboarding-service "$CHART" \
  "${CONSOLE_ARGS[@]}" --set externalSecret.credential=both >/dev/null 2>&1
check "an unknown credential mode fails the render" "$([ $? -ne 0 ] && echo 0 || echo 1)"

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
