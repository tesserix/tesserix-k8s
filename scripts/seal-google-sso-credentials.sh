#!/bin/bash
# =============================================================================
# Seal Google SSO Credentials Script
# =============================================================================
# Creates a SealedSecret for Google OAuth credentials used by Keycloak admin SSO
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "============================================="
echo "Seal Google SSO Credentials"
echo "============================================="
echo ""

# Check prerequisites
if ! command -v kubeseal &> /dev/null; then
    echo -e "${RED}Error: kubeseal is not installed${NC}"
    echo "Install with: brew install kubeseal"
    exit 1
fi

# Configuration
NAMESPACE="${NAMESPACE:-identity-customer}"
SECRET_NAME="${SECRET_NAME:-keycloak-google-sso}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/../charts/thirdparty/identity-customer/sealed-secrets}"

mkdir -p "$OUTPUT_DIR"

echo -e "${BLUE}Configuration:${NC}"
echo "  Namespace: $NAMESPACE"
echo "  Secret Name: $SECRET_NAME"
echo "  Output Directory: $OUTPUT_DIR"
echo ""

# Prompt for credentials
echo -e "${YELLOW}Enter Google OAuth credentials:${NC}"
echo ""
echo "To create these credentials:"
echo "  1. Go to https://console.cloud.google.com/apis/credentials"
echo "  2. Create an OAuth 2.0 Client ID (Web application)"
echo "  3. Add authorized redirect URIs for your Keycloak instances:"
echo "     - https://devtest-customer-idp.tesserix.app/realms/master/broker/google/endpoint"
echo "     - https://devtest-internal-idp.tesserix.app/realms/master/broker/google/endpoint"
echo ""

read -p "Google Client ID: " GOOGLE_CLIENT_ID
read -s -p "Google Client Secret: " GOOGLE_CLIENT_SECRET
echo ""

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    echo -e "${RED}Error: Both Client ID and Client Secret are required${NC}"
    exit 1
fi

# Check cluster connectivity
echo ""
echo -e "${BLUE}Checking cluster connectivity...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    echo "Make sure your kubeconfig is set correctly"
    exit 1
fi
echo -e "${GREEN}Connected to cluster${NC}"

# Create temporary secret YAML
TEMP_SECRET=$(mktemp)
cat > "$TEMP_SECRET" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/component: google-sso
type: Opaque
stringData:
  client-id: "${GOOGLE_CLIENT_ID}"
  client-secret: "${GOOGLE_CLIENT_SECRET}"
EOF

# Seal the secret
echo ""
echo -e "${BLUE}Sealing secret...${NC}"
SEALED_FILE="${OUTPUT_DIR}/${SECRET_NAME}.yaml"

kubeseal --format yaml < "$TEMP_SECRET" > "$SEALED_FILE"

# Clean up
rm -f "$TEMP_SECRET"

echo -e "${GREEN}Sealed secret created: ${SEALED_FILE}${NC}"
echo ""

# Also create for identity-internal
NAMESPACE_INTERNAL="identity-internal"
OUTPUT_DIR_INTERNAL="${SCRIPT_DIR}/../charts/thirdparty/identity-internal/sealed-secrets"
mkdir -p "$OUTPUT_DIR_INTERNAL"

TEMP_SECRET_INTERNAL=$(mktemp)
cat > "$TEMP_SECRET_INTERNAL" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE_INTERNAL}
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/component: google-sso
type: Opaque
stringData:
  client-id: "${GOOGLE_CLIENT_ID}"
  client-secret: "${GOOGLE_CLIENT_SECRET}"
EOF

SEALED_FILE_INTERNAL="${OUTPUT_DIR_INTERNAL}/${SECRET_NAME}.yaml"
kubeseal --format yaml < "$TEMP_SECRET_INTERNAL" > "$SEALED_FILE_INTERNAL"
rm -f "$TEMP_SECRET_INTERNAL"

echo -e "${GREEN}Sealed secret created: ${SEALED_FILE_INTERNAL}${NC}"
echo ""

# Summary
echo "============================================="
echo -e "${GREEN}Sealed Secrets Created Successfully${NC}"
echo "============================================="
echo ""
echo "Files created:"
echo "  - ${SEALED_FILE}"
echo "  - ${SEALED_FILE_INTERNAL}"
echo ""
echo "Next steps:"
echo "  1. Commit these sealed secrets to git"
echo "  2. Update ArgoCD app values to enable admin SSO:"
echo ""
echo "     adminSSO:"
echo "       enabled: true"
echo "       googleCredentialsSecret: \"${SECRET_NAME}\""
echo "       superAdmins:"
echo "         - \"unidevidp@gmail.com\""
echo "         - \"mahesh.sangawar@gmail.com\""
echo "         - \"samyak.rout@gmail.com\""
echo "       disablePasswordLogin: false"
echo ""
echo "  3. Sync ArgoCD applications"
echo ""
echo -e "${YELLOW}Google OAuth Redirect URIs (add to Google Console):${NC}"
echo "  - https://devtest-customer-idp.tesserix.app/realms/master/broker/google/endpoint"
echo "  - https://devtest-internal-idp.tesserix.app/realms/master/broker/google/endpoint"
echo ""
