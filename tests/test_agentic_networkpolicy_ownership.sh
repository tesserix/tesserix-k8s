#!/bin/bash
# The Vertex/PSC-aware AgentGateway egress policy has one ArgoCD owner. A
# generic istio-config copy makes both applications fight over the same object.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/thirdparty/istio-config"

{
  helm template istio-config "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prod.yaml"
  printf '\n---\n'
  cat "$REPO/manifests/agentic-istio/networkpolicy-agentgateway-egress.yaml"
} | python3 -c '
from collections import Counter
import sys

import yaml

resources = [doc for doc in yaml.safe_load_all(sys.stdin) if doc]
identities = Counter(
    (doc.get("kind"), doc.get("metadata", {}).get("namespace"), doc.get("metadata", {}).get("name"))
    for doc in resources
)
target = ("NetworkPolicy", "agentgateway-system", "allow-agentgateway-egress")
assert identities[target] == 1, f"{target} has {identities[target]} desired-state owners"
print("PASS AgentGateway egress policy has one desired-state owner")
'
