#!/usr/bin/env bash
# Patches ARC CRDs to support restartPolicy on init containers (sidecar pattern).
# Required because ARC 0.13.0 CRD schema is missing this field, preventing
# DinD (Docker-in-Docker) from running as a Kubernetes native sidecar container.
# Remove this script once ARC is upgraded to a version that includes the fix.

set -euo pipefail

CRDS=(
  "autoscalingrunnersets.actions.github.com:spec.template.spec.initContainers"
  "ephemeralrunners.actions.github.com:spec.spec.initContainers"
  "ephemeralrunnersets.actions.github.com:spec.ephemeralRunnerSpec.spec.initContainers"
)

for entry in "${CRDS[@]}"; do
  CRD="${entry%%:*}"
  JSON_PATH="${entry##*:}"

  # Convert dot path to JSON pointer
  POINTER=$(echo "$JSON_PATH" | sed 's/\./\/properties\//g')
  POINTER="/spec/versions/0/schema/openAPIV3Schema/properties/${POINTER}/items/properties/restartPolicy"

  # Check if already patched
  EXISTING=$(kubectl get crd "$CRD" -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
path = '${JSON_PATH}'.split('.')
schema = data['spec']['versions'][0]['schema']['openAPIV3Schema']
obj = schema
for p in path:
    obj = obj.get('properties', {}).get(p, {})
items_props = obj.get('items', {}).get('properties', {})
print('true' if 'restartPolicy' in items_props else 'false')
" 2>/dev/null || echo "false")

  if [ "$EXISTING" = "true" ]; then
    echo "CRD $CRD already has restartPolicy in initContainers schema"
  else
    echo "Patching CRD $CRD to add restartPolicy to initContainers schema..."
    kubectl patch crd "$CRD" --type=json -p="[
      {\"op\": \"add\", \"path\": \"${POINTER}\", \"value\": {\"type\": \"string\", \"description\": \"Restart policy for the init container. Set to Always for sidecar containers.\"}}
    ]"
    echo "Patched $CRD successfully"
  fi
done

echo "All ARC CRDs patched for sidecar container support."
