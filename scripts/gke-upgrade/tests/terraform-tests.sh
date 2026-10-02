#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="$ROOT/terraform-new/stacks/04-gke"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# The SDK provider mock cannot synthesize the absent master_auth block used by
# credential outputs. Exercise the real resources and inputs without outputs.
cp "$STACK/main.tf" "$STACK/variables.tf" "$STACK/providers.tf" "$STACK/.terraform.lock.hcl" "$TEST_DIR/"
cp "$STACK/auxiliary-node-pools.tf" "$TEST_DIR/"
cp -R "$STACK/tests" "$TEST_DIR/tests"
export TF_DATA_DIR="$TEST_DIR/.terraform"
terraform -chdir="$TEST_DIR" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null
terraform -chdir="$TEST_DIR" test -no-color
