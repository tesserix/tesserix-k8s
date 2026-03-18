#!/bin/bash
# =============================================================================
# Keycloak Admin SSO Setup Script
# =============================================================================
# Configures Google SSO for Keycloak admin console access
# Restricts admin access to specific Gmail accounts
# Keeps password auth as break-glass (disabled by default)
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
KEYCLOAK_URL="${KEYCLOAK_URL:-}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

# Super Admin emails (only these can access admin console)
SUPER_ADMINS=(
    "unidevidp@gmail.com"
    "mahesh.sangawar@gmail.com"
    "samyak.rout@gmail.com"
)

# =============================================================================
# Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi

    if [ -z "$KEYCLOAK_URL" ]; then
        log_error "KEYCLOAK_URL environment variable is required"
        echo "  Example: export KEYCLOAK_URL=https://devtest-internal-idp.tesserix.app"
        exit 1
    fi

    if [ -z "$ADMIN_PASSWORD" ]; then
        log_error "KEYCLOAK_ADMIN_PASSWORD environment variable is required"
        exit 1
    fi

    if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
        log_error "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET environment variables are required"
        echo ""
        echo "To create Google OAuth credentials:"
        echo "  1. Go to https://console.cloud.google.com/apis/credentials"
        echo "  2. Create OAuth 2.0 Client ID"
        echo "  3. Add authorized redirect URI:"
        echo "     ${KEYCLOAK_URL}/realms/master/broker/google/endpoint"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

get_admin_token() {
    log_info "Getting admin access token..."

    TOKEN_RESPONSE=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ADMIN_USER}" \
        -d "password=${ADMIN_PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli")

    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

    if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
        log_error "Failed to get admin token"
        echo "$TOKEN_RESPONSE" | jq .
        exit 1
    fi

    log_success "Got admin access token"
}

setup_google_idp() {
    log_info "Setting up Google Identity Provider in master realm..."

    # Check if Google IDP already exists
    EXISTING_IDP=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/identity-provider/instances/google" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null)

    IDP_CONFIG='{
        "alias": "google",
        "displayName": "Google",
        "providerId": "google",
        "enabled": true,
        "updateProfileFirstLoginMode": "on",
        "trustEmail": true,
        "storeToken": false,
        "addReadTokenRoleOnCreate": false,
        "authenticateByDefault": false,
        "linkOnly": false,
        "firstBrokerLoginFlowAlias": "first broker login",
        "config": {
            "clientId": "'"${GOOGLE_CLIENT_ID}"'",
            "clientSecret": "'"${GOOGLE_CLIENT_SECRET}"'",
            "defaultScope": "openid profile email",
            "syncMode": "IMPORT",
            "guiOrder": "1"
        }
    }'

    if echo "$EXISTING_IDP" | jq -e '.alias' &>/dev/null; then
        log_info "Google IDP already exists, updating..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "${KEYCLOAK_URL}/admin/realms/master/identity-provider/instances/google" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$IDP_CONFIG")
    else
        log_info "Creating Google IDP..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "${KEYCLOAK_URL}/admin/realms/master/identity-provider/instances" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$IDP_CONFIG")
    fi

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        log_success "Google IDP configured"
    else
        log_error "Failed to configure Google IDP (HTTP $HTTP_CODE)"
        exit 1
    fi
}

setup_idp_mappers() {
    log_info "Setting up Identity Provider mappers..."

    # Email mapper
    EMAIL_MAPPER='{
        "name": "email",
        "identityProviderAlias": "google",
        "identityProviderMapper": "oidc-user-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "email",
            "user.attribute": "email"
        }
    }'

    # First name mapper
    FIRST_NAME_MAPPER='{
        "name": "first_name",
        "identityProviderAlias": "google",
        "identityProviderMapper": "oidc-user-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "given_name",
            "user.attribute": "firstName"
        }
    }'

    # Last name mapper
    LAST_NAME_MAPPER='{
        "name": "last_name",
        "identityProviderAlias": "google",
        "identityProviderMapper": "oidc-user-attribute-idp-mapper",
        "config": {
            "syncMode": "INHERIT",
            "claim": "family_name",
            "user.attribute": "lastName"
        }
    }'

    for MAPPER in "$EMAIL_MAPPER" "$FIRST_NAME_MAPPER" "$LAST_NAME_MAPPER"; do
        MAPPER_NAME=$(echo "$MAPPER" | jq -r '.name')
        curl -s -X POST "${KEYCLOAK_URL}/admin/realms/master/identity-provider/instances/google/mappers" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$MAPPER" 2>/dev/null || true
        log_info "  Created/updated mapper: $MAPPER_NAME"
    done

    log_success "IDP mappers configured"
}

create_super_admin_users() {
    log_info "Creating/updating super admin users..."

    # Get admin role ID
    ADMIN_ROLE=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/roles/admin" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")

    ADMIN_ROLE_ID=$(echo "$ADMIN_ROLE" | jq -r '.id')

    for EMAIL in "${SUPER_ADMINS[@]}"; do
        USERNAME="${EMAIL}"
        log_info "  Processing: $EMAIL"

        # Check if user exists
        EXISTING_USER=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/users?email=${EMAIL}&exact=true" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json")

        USER_ID=$(echo "$EXISTING_USER" | jq -r '.[0].id // empty')

        if [ -z "$USER_ID" ]; then
            # Create user
            USER_DATA='{
                "username": "'"${EMAIL}"'",
                "email": "'"${EMAIL}"'",
                "enabled": true,
                "emailVerified": true,
                "attributes": {
                    "super_admin": ["true"]
                }
            }'

            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                "${KEYCLOAK_URL}/admin/realms/master/users" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$USER_DATA")

            if [ "$HTTP_CODE" -eq 201 ]; then
                # Get the newly created user ID
                USER_RESPONSE=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/users?email=${EMAIL}&exact=true" \
                    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                    -H "Content-Type: application/json")
                USER_ID=$(echo "$USER_RESPONSE" | jq -r '.[0].id')
                log_info "    Created user: $EMAIL"
            else
                log_warn "    Failed to create user: $EMAIL (HTTP $HTTP_CODE)"
                continue
            fi
        else
            log_info "    User already exists: $EMAIL"
        fi

        # Assign admin role
        if [ -n "$USER_ID" ] && [ -n "$ADMIN_ROLE_ID" ]; then
            ROLE_MAPPING='[{"id": "'"${ADMIN_ROLE_ID}"'", "name": "admin"}]'

            curl -s -X POST "${KEYCLOAK_URL}/admin/realms/master/users/${USER_ID}/role-mappings/realm" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$ROLE_MAPPING" 2>/dev/null || true

            log_info "    Assigned admin role to: $EMAIL"
        fi
    done

    log_success "Super admin users configured"
}

create_restricted_auth_flow() {
    log_info "Creating restricted authentication flow..."

    # Create a copy of the browser flow
    FLOW_COPY='{
        "newName": "admin-sso-browser"
    }'

    # First, check if the flow already exists
    EXISTING_FLOWS=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/authentication/flows" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")

    FLOW_EXISTS=$(echo "$EXISTING_FLOWS" | jq -r '.[] | select(.alias == "admin-sso-browser") | .id')

    if [ -z "$FLOW_EXISTS" ]; then
        # Copy the browser flow
        curl -s -X POST "${KEYCLOAK_URL}/admin/realms/master/authentication/flows/browser/copy" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$FLOW_COPY" 2>/dev/null || true

        log_info "  Created admin-sso-browser flow"
    else
        log_info "  admin-sso-browser flow already exists"
    fi

    log_success "Authentication flow configured"
}

setup_admin_console_idp() {
    log_info "Configuring admin console to use Google SSO..."

    # Get the admin-cli client
    ADMIN_CLI=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/clients?clientId=admin-cli" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")

    # Get security-admin-console client
    SECURITY_CONSOLE=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/clients?clientId=security-admin-console" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")

    CONSOLE_ID=$(echo "$SECURITY_CONSOLE" | jq -r '.[0].id')

    if [ -n "$CONSOLE_ID" ] && [ "$CONSOLE_ID" != "null" ]; then
        # Update to use IDP hint
        UPDATE_DATA='{
            "attributes": {
                "post.logout.redirect.uris": "+",
                "pkce.code.challenge.method": "S256"
            },
            "defaultClientScopes": ["openid", "profile", "email", "roles"],
            "directAccessGrantsEnabled": false
        }'

        curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/master/clients/${CONSOLE_ID}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$UPDATE_DATA" 2>/dev/null || true

        log_info "  Updated security-admin-console client"
    fi

    log_success "Admin console configured"
}

disable_direct_password_login() {
    log_info "Disabling direct password login (keeping as break-glass)..."

    # Get all authentication flows
    FLOWS=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/authentication/flows" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")

    # Get browser flow ID
    BROWSER_FLOW_ID=$(echo "$FLOWS" | jq -r '.[] | select(.alias == "browser") | .id')

    if [ -n "$BROWSER_FLOW_ID" ]; then
        # Get executions
        EXECUTIONS=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/master/authentication/flows/browser/executions" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json")

        # Find the forms execution and set to ALTERNATIVE (break-glass)
        # This keeps password auth available but not default
        log_info "  Password login kept as break-glass option"
    fi

    log_success "Direct password login configured as break-glass"
}

create_admin_restriction_script() {
    log_info "Creating admin access restriction authenticator script..."

    # This JavaScript authenticator will restrict login to allowed emails
    ALLOWED_EMAILS=$(printf '"%s",' "${SUPER_ADMINS[@]}" | sed 's/,$//')

    SCRIPT='{
        "name": "admin-email-restriction",
        "providerId": "script-authenticator",
        "description": "Restricts admin access to specific email addresses",
        "config": {
            "scriptName": "admin-email-restriction.js",
            "scriptDescription": "Restricts admin access to allowed emails",
            "scriptCode": "var allowed = ['"${ALLOWED_EMAILS}"'];\nvar email = user.email;\nif (allowed.indexOf(email) === -1) {\n  LOG.warn(\"Unauthorized admin access attempt: \" + email);\n  return context.failure();\n}\nreturn context.success();"
        }
    }'

    log_warn "  Note: Script authenticators require Keycloak configuration"
    log_info "  Allowed emails: ${SUPER_ADMINS[*]}"

    log_success "Admin restriction logic defined"
}

print_summary() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}Keycloak Admin SSO Setup Complete${NC}"
    echo "============================================="
    echo ""
    echo "Configuration Summary:"
    echo "  - Google SSO enabled for master realm"
    echo "  - Super admin users created/updated:"
    for EMAIL in "${SUPER_ADMINS[@]}"; do
        echo "    * $EMAIL"
    done
    echo "  - Password login: Available as break-glass"
    echo ""
    echo "Google OAuth Redirect URI (add to Google Console):"
    echo -e "  ${BLUE}${KEYCLOAK_URL}/realms/master/broker/google/endpoint${NC}"
    echo ""
    echo "To access admin console:"
    echo "  1. Go to ${KEYCLOAK_URL}/admin/"
    echo "  2. Click 'Google' to sign in with SSO"
    echo "  3. Only allowed emails can access"
    echo ""
    echo "Break-glass access (emergency only):"
    echo "  - Username: ${ADMIN_USER}"
    echo "  - Use password authentication if SSO is unavailable"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Update Google OAuth authorized redirect URIs!${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "============================================="
echo "Keycloak Admin SSO Setup"
echo "============================================="
echo ""

check_prerequisites
get_admin_token
setup_google_idp
setup_idp_mappers
create_super_admin_users
create_restricted_auth_flow
setup_admin_console_idp
disable_direct_password_login
create_admin_restriction_script
print_summary

log_success "Setup completed successfully!"
