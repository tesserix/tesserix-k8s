#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO/charts/apps/agentic-registry"

helm template agentregistry "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prod.yaml" \
  | python3 -c '
import sys

import yaml

resources = [document for document in yaml.safe_load_all(sys.stdin) if document]
deployment = next(
    resource
    for resource in resources
    if resource.get("kind") == "Deployment" and resource["metadata"]["name"] == "agentregistry"
)
external_secret = next(
    resource
    for resource in resources
    if resource.get("kind") == "ExternalSecret"
    and resource["metadata"]["name"] == "agentregistry-secrets"
)

assert deployment["metadata"]["annotations"]["secret.reloader.stakater.com/reload"] == "agentregistry-secrets"
assert external_secret["metadata"]["annotations"]["force-sync"] == "kora-deploy-key-v2"
print("PASS Agent Registry reconciles and reloads rotated secrets")
'
