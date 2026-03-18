#!/bin/bash
# =============================================================================
# Create Google OAuth Sealed Secrets for Keycloak IDPs
# =============================================================================
# This script creates sealed secrets for Google OAuth credentials
# for both identity-customer and identity-internal namespaces.
#
# Prerequisites:
# - kubeseal CLI installed
# - kubectl configured with access to the cluster
# - Access to sealed-secrets controller
#
# Usage:
#   ./create-google-idp-secrets.sh
#
# You will be prompted to enter:
# - Customer IDP: Google Client ID and Client Secret
# - Internal IDP: Google Client ID and Client Secret
# =============================================================================

set -e

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/gke-devtest}"
CONTROLLER_NAMESPACE="sealed-secrets"
CONTROLLER_NAME="sealed-secrets"
OUTPUT_DIR="../argocd/devtest/infrastructure"

echo "=============================================="
echo "Google OAuth Sealed Secrets Generator"
echo "=============================================="
echo ""

# Check prerequisites
command -v kubeseal >/dev/null 2>&1 || { echo "kubeseal is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting."; exit 1; }

# Set KUBECONFIG
export KUBECONFIG="$KUBECONFIG_PATH"

echo "Using KUBECONFIG: $KUBECONFIG"
echo ""

# -----------------------------------------------------------------------------
# Identity-Customer (Storefront) Google OAuth
# -----------------------------------------------------------------------------
echo "=== Identity-Customer (Storefront) Google OAuth ==="
echo "Enter the Google OAuth credentials for CUSTOMER IDP:"
echo "(URL: https://devtest-customer-idp.tesserix.app)"
echo ""

read -p "Google Client ID: " CUSTOMER_CLIENT_ID
read -sp "Google Client Secret: " CUSTOMER_CLIENT_SECRET
echo ""

if [[ -z "$CUSTOMER_CLIENT_ID" || -z "$CUSTOMER_CLIENT_SECRET" ]]; then
    echo "Error: Client ID and Secret are required for Customer IDP"
    exit 1
fi

echo "Creating sealed secret for identity-customer namespace..."

kubectl create secret generic keycloak-idp-google \
    --namespace=identity-customer \
    --from-literal=client-id="$CUSTOMER_CLIENT_ID" \
    --from-literal=client-secret="$CUSTOMER_CLIENT_SECRET" \
    --dry-run=client -o yaml | \
    kubeseal --controller-namespace="$CONTROLLER_NAMESPACE" \
             --controller-name="$CONTROLLER_NAME" \
             --format=yaml > "$OUTPUT_DIR/identity-customer-google-idp.yaml"

echo "Created: $OUTPUT_DIR/identity-customer-google-idp.yaml"
echo ""

# -----------------------------------------------------------------------------
# Identity-Internal (Admin) Google OAuth
# -----------------------------------------------------------------------------
echo "=== Identity-Internal (Admin) Google OAuth ==="
echo "Enter the Google OAuth credentials for INTERNAL IDP:"
echo "(URL: https://devtest-internal-idp.tesserix.app)"
echo ""

read -p "Google Client ID: " INTERNAL_CLIENT_ID
read -sp "Google Client Secret: " INTERNAL_CLIENT_SECRET
echo ""

if [[ -z "$INTERNAL_CLIENT_ID" || -z "$INTERNAL_CLIENT_SECRET" ]]; then
    echo "Error: Client ID and Secret are required for Internal IDP"
    exit 1
fi

echo "Creating sealed secret for identity-internal namespace..."

kubectl create secret generic keycloak-idp-google \
    --namespace=identity-internal \
    --from-literal=client-id="$INTERNAL_CLIENT_ID" \
    --from-literal=client-secret="$INTERNAL_CLIENT_SECRET" \
    --dry-run=client -o yaml | \
    kubeseal --controller-namespace="$CONTROLLER_NAMESPACE" \
             --controller-name="$CONTROLLER_NAME" \
             --format=yaml > "$OUTPUT_DIR/identity-internal-google-idp.yaml"

echo "Created: $OUTPUT_DIR/identity-internal-google-idp.yaml"
echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "=============================================="
echo "Sealed Secrets Created Successfully!"
echo "=============================================="
echo ""
echo "Files created:"
echo "  - $OUTPUT_DIR/identity-customer-google-idp.yaml"
echo "  - $OUTPUT_DIR/identity-internal-google-idp.yaml"
echo ""
echo "Next steps:"
echo "  1. Review the generated files"
echo "  2. Commit and push to Git"
echo "  3. ArgoCD will sync the secrets to the cluster"
echo "  4. Configure Google IDP in Keycloak Admin Console"
echo ""
echo "Keycloak Admin Console URLs:"
echo "  - Customer: https://devtest-customer-idp.tesserix.app/admin"
echo "  - Internal: https://devtest-internal-idp.tesserix.app/admin"
echo ""
