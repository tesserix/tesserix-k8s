#!/bin/bash
# =============================================================================
# Configure Google Identity Provider via Keycloak Admin API
# =============================================================================
# This script configures Google OAuth as an Identity Provider in Keycloak.
#
# Prerequisites:
# - curl, jq installed
# - Keycloak admin credentials
# - Google OAuth Client ID and Secret
#
# Usage:
#   ./configure-google-idp.sh [customer|internal]
# =============================================================================

set -e

IDP_TYPE="${1:-customer}"

case "$IDP_TYPE" in
    customer)
        KEYCLOAK_URL="https://devtest-customer-idp.tesserix.app"
        REALM="tesserix-customer"
        echo "Configuring Google IDP for CUSTOMER (Storefront)"
        ;;
    internal)
        KEYCLOAK_URL="https://devtest-internal-idp.tesserix.app"
        REALM="tesserix-internal"
        echo "Configuring Google IDP for INTERNAL (Admin)"
        ;;
    *)
        echo "Usage: $0 [customer|internal]"
        exit 1
        ;;
esac

echo ""
echo "Keycloak URL: $KEYCLOAK_URL"
echo "Realm: $REALM"
echo ""

# Get admin credentials
read -p "Keycloak Admin Username: " ADMIN_USER
read -sp "Keycloak Admin Password: " ADMIN_PASS
echo ""

# Get Google OAuth credentials
echo ""
echo "Enter Google OAuth credentials:"
read -p "Google Client ID: " GOOGLE_CLIENT_ID
read -sp "Google Client Secret: " GOOGLE_CLIENT_SECRET
echo ""

# Get access token
echo "Authenticating with Keycloak..."
ACCESS_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "Error: Failed to authenticate with Keycloak"
    exit 1
fi

echo "Authentication successful!"

# Check if realm exists
echo "Checking if realm '$REALM' exists..."
REALM_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}")

if [[ "$REALM_CHECK" != "200" ]]; then
    echo "Creating realm '$REALM'..."
    curl -s -X POST "${KEYCLOAK_URL}/admin/realms" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "realm": "'"$REALM"'",
            "enabled": true,
            "displayName": "Tesseract Hub",
            "registrationAllowed": true,
            "registrationEmailAsUsername": true,
            "rememberMe": true,
            "verifyEmail": true,
            "loginWithEmailAllowed": true,
            "duplicateEmailsAllowed": false,
            "resetPasswordAllowed": true,
            "bruteForceProtected": true,
            "accessTokenLifespan": 300,
            "ssoSessionIdleTimeout": 1800,
            "ssoSessionMaxLifespan": 36000
        }'
    echo "Realm created!"
else
    echo "Realm '$REALM' already exists"
fi

# Check if Google IDP exists
echo "Checking if Google IDP exists..."
IDP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances/google")

# Create or update Google IDP
IDP_CONFIG='{
    "alias": "google",
    "providerId": "google",
    "enabled": true,
    "displayName": "Sign in with Google",
    "trustEmail": true,
    "storeToken": false,
    "addReadTokenRoleOnCreate": false,
    "authenticateByDefault": false,
    "linkOnly": false,
    "firstBrokerLoginFlowAlias": "first broker login",
    "config": {
        "clientId": "'"$GOOGLE_CLIENT_ID"'",
        "clientSecret": "'"$GOOGLE_CLIENT_SECRET"'",
        "defaultScope": "openid email profile",
        "syncMode": "IMPORT",
        "useJwksUrl": "true"
    }
}'

if [[ "$IDP_CHECK" == "200" ]]; then
    echo "Updating existing Google IDP..."
    curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances/google" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$IDP_CONFIG"
else
    echo "Creating Google IDP..."
    curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$IDP_CONFIG"
fi

echo "Google IDP configured!"

# Add attribute mappers
echo "Adding attribute mappers..."

# Email mapper
curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances/google/mappers" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "email",
        "identityProviderAlias": "google",
        "identityProviderMapper": "hardcoded-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "email",
            "user.attribute": "email"
        }
    }' 2>/dev/null || true

# First name mapper
curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances/google/mappers" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "firstName",
        "identityProviderAlias": "google",
        "identityProviderMapper": "hardcoded-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "given_name",
            "user.attribute": "firstName"
        }
    }' 2>/dev/null || true

# Last name mapper
curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances/google/mappers" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "lastName",
        "identityProviderAlias": "google",
        "identityProviderMapper": "hardcoded-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "family_name",
            "user.attribute": "lastName"
        }
    }' 2>/dev/null || true

echo "Attribute mappers added!"

echo ""
echo "=============================================="
echo "Google IDP Configuration Complete!"
echo "=============================================="
echo ""
echo "Keycloak Admin Console: ${KEYCLOAK_URL}/admin"
echo "Login Page: ${KEYCLOAK_URL}/realms/${REALM}/account"
echo ""
echo "The 'Sign in with Google' button should now appear on the login page."
echo ""
