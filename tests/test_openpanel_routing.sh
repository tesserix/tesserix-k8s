#!/bin/bash
# Route-precedence tests for the openpanel VirtualService. Istio matches http
# rules in order, so what matters is which rule a path hits first.
# Usage: tests/test_openpanel_routing.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/thirdparty/openpanel"

helm template openpanel "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prod.yaml" \
  | python3 -c '
import sys, yaml

for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "VirtualService":
        routes = doc["spec"]["http"]
        break
else:
    sys.exit("openpanel VirtualService not found in rendered chart")


def matches(match, path):
    uri = match.get("uri", {})
    if "exact" in uri:
        return uri["exact"] == path
    if "prefix" in uri:
        return path.startswith(uri["prefix"])
    return not uri


def first_destination(path):
    for route in routes:
        if any(matches(m, path) for m in route.get("match", [{}])):
            return route["route"][0]["destination"]["host"]
    raise AssertionError(f"no route matches {path}")


pass_count = fail_count = 0


def check(name, actual, expected):
    global pass_count, fail_count
    if expected in actual:
        print(f"  PASS {name}")
        pass_count += 1
    else:
        print(f"  FAIL {name}: expected {expected!r}, got {actual!r}")
        fail_count += 1


print("the tracking script is public")
check("/op1.js reaches the dashboard, not the auth proxy",
      first_destination("/op1.js"), "openpanel-dashboard")

print("everything else keeps its current route")
check("event ingestion still reaches the api",
      first_destination("/api/track"), "openpanel-api")
check("the dashboard itself stays behind the auth proxy",
      first_destination("/"), "openpanel-oauth2-proxy")
check("the sign-in flow stays on the auth proxy",
      first_destination("/api/oauth/start"), "openpanel-oauth2-proxy")

print()
print(f"passed={pass_count} failed={fail_count}")
sys.exit(1 if fail_count else 0)
'
