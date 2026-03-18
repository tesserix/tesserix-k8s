#!/bin/bash
# =============================================================================
# KEYCLOAK REALM SETUP SCRIPT
# =============================================================================
# This script configures Keycloak realms for Tesseract Hub:
# - tesseract-customer: For storefront/mobile app users
# - tesserix-internal: For admin/staff users
#
# Prerequisites:
# - kubectl access to the cluster
# - Keycloak pods running
# - Admin credentials available
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
KUBECONFIG="${KUBECONFIG:-/Users/samyakrout/.kube/gke-devtest}"

# Customer IDP
CUSTOMER_NAMESPACE="identity-customer"
CUSTOMER_KEYCLOAK_URL="https://devtest-customer-idp.tesserix.app"
CUSTOMER_REALM="tesseract-customer"

# Internal IDP
INTERNAL_NAMESPACE="identity-internal"
INTERNAL_KEYCLOAK_URL="https://devtest-internal-idp.tesserix.app"
INTERNAL_REALM="tesserix-internal"

# App URLs (for redirect URIs)
STOREFRONT_URL="https://devtest.tesserix.app"
ADMIN_URL="https://admin-devtest.tesserix.app"
MOBILE_SCHEME="com.tesseract.mobile"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
get_admin_token() {
    local keycloak_url=$1
    local namespace=$2

    # Get admin credentials from secret
    local admin_user=$(KUBECONFIG=$KUBECONFIG kubectl get secret keycloak-admin-credentials -n "$namespace" -o jsonpath='{.data.username}' | base64 -d)
    local admin_pass=$(KUBECONFIG=$KUBECONFIG kubectl get secret keycloak-admin-credentials -n "$namespace" -o jsonpath='{.data.password}' | base64 -d)

    # Get token
    local token=$(curl -s -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')

    if [ "$token" == "null" ] || [ -z "$token" ]; then
        log_error "Failed to get admin token from $keycloak_url"
        return 1
    fi

    echo "$token"
}

check_realm_exists() {
    local keycloak_url=$1
    local realm=$2
    local token=$3

    local status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $token" \
        "${keycloak_url}/admin/realms/${realm}")

    [ "$status" == "200" ]
}

# -----------------------------------------------------------------------------
# Create Customer Realm
# -----------------------------------------------------------------------------
create_customer_realm() {
    log_info "Setting up Customer Realm: $CUSTOMER_REALM"

    local token=$(get_admin_token "$CUSTOMER_KEYCLOAK_URL" "$CUSTOMER_NAMESPACE")

    if check_realm_exists "$CUSTOMER_KEYCLOAK_URL" "$CUSTOMER_REALM" "$token"; then
        log_warn "Realm $CUSTOMER_REALM already exists, updating..."
    else
        log_info "Creating realm $CUSTOMER_REALM..."
    fi

    # Create/Update realm
    curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d @- << EOF
{
    "realm": "${CUSTOMER_REALM}",
    "enabled": true,
    "displayName": "Tesseract Customer Portal",
    "displayNameHtml": "<strong>Tesseract</strong> Customer Portal",
    "registrationAllowed": true,
    "registrationEmailAsUsername": true,
    "rememberMe": true,
    "verifyEmail": true,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "resetPasswordAllowed": true,
    "editUsernameAllowed": false,
    "bruteForceProtected": true,
    "permanentLockout": false,
    "maxFailureWaitSeconds": 900,
    "minimumQuickLoginWaitSeconds": 60,
    "waitIncrementSeconds": 60,
    "quickLoginCheckMilliSeconds": 1000,
    "maxDeltaTimeSeconds": 43200,
    "failureFactor": 5,
    "passwordPolicy": "length(8) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1)",
    "sslRequired": "external",
    "accessTokenLifespan": 300,
    "accessTokenLifespanForImplicitFlow": 900,
    "ssoSessionIdleTimeout": 1800,
    "ssoSessionMaxLifespan": 36000,
    "offlineSessionIdleTimeout": 2592000,
    "offlineSessionMaxLifespanEnabled": false,
    "accessCodeLifespan": 60,
    "accessCodeLifespanUserAction": 300,
    "accessCodeLifespanLogin": 1800,
    "actionTokenGeneratedByAdminLifespan": 43200,
    "actionTokenGeneratedByUserLifespan": 300,
    "internationalizationEnabled": true,
    "supportedLocales": ["en", "de", "fr", "es"],
    "defaultLocale": "en",
    "loginTheme": "keycloak",
    "accountTheme": "keycloak",
    "adminTheme": "keycloak",
    "emailTheme": "keycloak",
    "smtpServer": {},
    "eventsEnabled": true,
    "eventsListeners": ["jboss-logging"],
    "enabledEventTypes": ["LOGIN", "LOGIN_ERROR", "LOGOUT", "REGISTER", "REGISTER_ERROR"],
    "adminEventsEnabled": true,
    "adminEventsDetailsEnabled": true
}
EOF

    # Create if PUT failed (realm doesn't exist)
    if [ $? -ne 0 ]; then
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d @- << EOF
{
    "realm": "${CUSTOMER_REALM}",
    "enabled": true,
    "displayName": "Tesseract Customer Portal",
    "registrationAllowed": true,
    "registrationEmailAsUsername": true,
    "rememberMe": true,
    "verifyEmail": true,
    "loginWithEmailAllowed": true,
    "resetPasswordAllowed": true,
    "bruteForceProtected": true,
    "passwordPolicy": "length(8) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1)"
}
EOF
    fi

    log_success "Customer realm configured"

    # Create storefront client
    create_storefront_client "$token"

    # Create mobile client
    create_mobile_client "$token"

    # Create marketplace dashboard client (for direct grant authentication)
    create_marketplace_dashboard_client "$token"

    # Create marketplace onboarding admin client (for user management)
    create_marketplace_onboarding_admin_client "$token"

    # Create test user
    create_customer_test_user "$token"
}

create_storefront_client() {
    local token=$1

    log_info "Creating storefront client..."

    # Check if client exists
    local client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=storefront-web" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "storefront-web",
        "name": "Tesseract Storefront",
        "description": "Customer-facing web application",
        "enabled": true,
        "publicClient": true,
        "standardFlowEnabled": true,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": false,
        "serviceAccountsEnabled": false,
        "authorizationServicesEnabled": false,
        "protocol": "openid-connect",
        "rootUrl": "'${STOREFRONT_URL}'",
        "baseUrl": "'${STOREFRONT_URL}'",
        "redirectUris": [
            "'${STOREFRONT_URL}'/*",
            "http://localhost:3000/*",
            "http://localhost:4200/*"
        ],
        "webOrigins": [
            "'${STOREFRONT_URL}'",
            "http://localhost:3000",
            "http://localhost:4200"
        ],
        "attributes": {
            "pkce.code.challenge.method": "S256",
            "post.logout.redirect.uris": "'${STOREFRONT_URL}'/*##http://localhost:3000/*"
        },
        "defaultClientScopes": ["openid", "email", "profile", "roles"],
        "optionalClientScopes": ["address", "phone", "offline_access"]
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    log_success "Storefront client configured"
}

create_mobile_client() {
    local token=$1

    log_info "Creating mobile client..."

    local client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=storefront-mobile" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "storefront-mobile",
        "name": "Tesseract Mobile App",
        "description": "Mobile application for customers",
        "enabled": true,
        "publicClient": true,
        "standardFlowEnabled": true,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": false,
        "serviceAccountsEnabled": false,
        "authorizationServicesEnabled": false,
        "protocol": "openid-connect",
        "redirectUris": [
            "'${MOBILE_SCHEME}'://callback",
            "'${MOBILE_SCHEME}'://auth/callback",
            "exp://localhost:19000/--/auth/callback",
            "exp://localhost:8081/--/auth/callback"
        ],
        "webOrigins": ["+"],
        "attributes": {
            "pkce.code.challenge.method": "S256",
            "post.logout.redirect.uris": "'${MOBILE_SCHEME}'://logout"
        },
        "defaultClientScopes": ["openid", "email", "profile", "roles", "offline_access"],
        "optionalClientScopes": ["address", "phone"]
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    log_success "Mobile client configured"
}

# -----------------------------------------------------------------------------
# Marketplace Dashboard Client (for direct grant / password authentication)
# Used by tenant-service to authenticate users with password grant
# -----------------------------------------------------------------------------
create_marketplace_dashboard_client() {
    local token=$1

    log_info "Creating marketplace-dashboard client (confidential, direct grant)..."

    local client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=marketplace-dashboard" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "marketplace-dashboard",
        "name": "Marketplace Dashboard",
        "description": "Confidential client for tenant admin dashboard authentication via direct grant",
        "enabled": true,
        "publicClient": false,
        "standardFlowEnabled": true,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": true,
        "serviceAccountsEnabled": false,
        "authorizationServicesEnabled": false,
        "protocol": "openid-connect",
        "redirectUris": [
            "https://*-admin.tesserix.app/*",
            "http://localhost:3000/*",
            "http://localhost:3001/*"
        ],
        "webOrigins": ["+"],
        "attributes": {
            "pkce.code.challenge.method": "S256"
        },
        "defaultClientScopes": ["openid", "email", "profile", "roles"],
        "optionalClientScopes": ["offline_access"]
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    # Get client UUID and secret
    client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=marketplace-dashboard" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id')

    local secret=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}/client-secret" \
        -H "Authorization: Bearer $token" | jq -r '.value')

    log_success "Marketplace dashboard client configured"
    log_info "  Client Secret: $secret"
    log_info "  Save this as: keycloak_customer_dashboard_client_secret in GitHub secrets and Terraform"
    echo "$secret" > /tmp/marketplace-dashboard-secret.txt
}

# -----------------------------------------------------------------------------
# Marketplace Onboarding Admin Client (for user management)
# Used by tenant-service for creating users, managing credentials, etc.
# -----------------------------------------------------------------------------
create_marketplace_onboarding_admin_client() {
    local token=$1

    log_info "Creating marketplace-onboarding-admin client (service account)..."

    local client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=marketplace-onboarding-admin" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "marketplace-onboarding-admin",
        "name": "Marketplace Onboarding Admin",
        "description": "Service account client for tenant onboarding and user management",
        "enabled": true,
        "publicClient": false,
        "standardFlowEnabled": false,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": true,
        "serviceAccountsEnabled": true,
        "authorizationServicesEnabled": false,
        "protocol": "openid-connect",
        "redirectUris": [],
        "webOrigins": [],
        "attributes": {},
        "defaultClientScopes": ["openid", "email", "profile"],
        "optionalClientScopes": []
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    # Get client UUID
    client_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=marketplace-onboarding-admin" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id')

    # Get service account user ID
    local service_account_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}/service-account-user" \
        -H "Authorization: Bearer $token" | jq -r '.id')

    # Get realm-management client UUID for role assignment
    local realm_mgmt_client=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients?clientId=realm-management" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id')

    # Get manage-users role
    local manage_users_role=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${realm_mgmt_client}/roles/manage-users" \
        -H "Authorization: Bearer $token")

    # Assign manage-users role to service account
    curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users/${service_account_id}/role-mappings/clients/${realm_mgmt_client}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "[$manage_users_role]"

    # Get view-users role and assign it too
    local view_users_role=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${realm_mgmt_client}/roles/view-users" \
        -H "Authorization: Bearer $token")

    curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users/${service_account_id}/role-mappings/clients/${realm_mgmt_client}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "[$view_users_role]"

    # Get client secret
    local secret=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/clients/${client_id}/client-secret" \
        -H "Authorization: Bearer $token" | jq -r '.value')

    log_success "Marketplace onboarding admin client configured"
    log_info "  Client Secret: $secret"
    log_info "  Service account has: manage-users, view-users roles"
    log_info "  Save this as: keycloak_customer_admin_client_secret in GitHub secrets and Terraform"
    echo "$secret" > /tmp/marketplace-onboarding-admin-secret.txt
}

create_customer_test_user() {
    local token=$1

    log_info "Creating test customer user..."

    # Check if user exists
    local user_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users?email=samyak.rout@gmail.com" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    if [ -n "$user_id" ]; then
        log_warn "User samyak.rout@gmail.com already exists, updating..."

        # Update user
        curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users/${user_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d '{
                "enabled": true,
                "emailVerified": true,
                "firstName": "Samyak",
                "lastName": "Rout",
                "attributes": {
                    "tenant_id": ["00000000-0000-0000-0000-000000000001"],
                    "tenant_slug": ["primary"]
                }
            }'
    else
        # Create user
        curl -s -X POST "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d '{
                "username": "samyak.rout@gmail.com",
                "email": "samyak.rout@gmail.com",
                "enabled": true,
                "emailVerified": true,
                "firstName": "Samyak",
                "lastName": "Rout",
                "attributes": {
                    "tenant_id": ["00000000-0000-0000-0000-000000000001"],
                    "tenant_slug": ["primary"]
                },
                "credentials": [{
                    "type": "password",
                    "value": "***REMOVED***",
                    "temporary": false
                }]
            }'

        # Get new user ID
        user_id=$(curl -s -X GET "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users?email=samyak.rout@gmail.com" \
            -H "Authorization: Bearer $token" | jq -r '.[0].id')
    fi

    # Set password (in case user existed)
    curl -s -X PUT "${CUSTOMER_KEYCLOAK_URL}/admin/realms/${CUSTOMER_REALM}/users/${user_id}/reset-password" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "password",
            "value": "***REMOVED***",
            "temporary": false
        }'

    log_success "Customer test user created: samyak.rout@gmail.com / ***REMOVED***"
}

# -----------------------------------------------------------------------------
# Create Internal Realm
# -----------------------------------------------------------------------------
create_internal_realm() {
    log_info "Setting up Internal Realm: $INTERNAL_REALM"

    local token=$(get_admin_token "$INTERNAL_KEYCLOAK_URL" "$INTERNAL_NAMESPACE")

    if check_realm_exists "$INTERNAL_KEYCLOAK_URL" "$INTERNAL_REALM" "$token"; then
        log_warn "Realm $INTERNAL_REALM already exists, updating..."
    else
        log_info "Creating realm $INTERNAL_REALM..."
    fi

    # Create/Update realm
    curl -s -X PUT "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d @- << EOF || curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d @- << EOF2
{
    "realm": "${INTERNAL_REALM}",
    "enabled": true,
    "displayName": "Tesseract Admin Portal",
    "displayNameHtml": "<strong>Tesseract</strong> Admin Portal",
    "registrationAllowed": false,
    "rememberMe": true,
    "verifyEmail": false,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "resetPasswordAllowed": true,
    "editUsernameAllowed": false,
    "bruteForceProtected": true,
    "permanentLockout": true,
    "maxFailureWaitSeconds": 3600,
    "minimumQuickLoginWaitSeconds": 120,
    "waitIncrementSeconds": 120,
    "quickLoginCheckMilliSeconds": 1000,
    "maxDeltaTimeSeconds": 86400,
    "failureFactor": 3,
    "passwordPolicy": "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(2) and notUsername",
    "sslRequired": "all",
    "accessTokenLifespan": 300,
    "ssoSessionIdleTimeout": 900,
    "ssoSessionMaxLifespan": 14400,
    "offlineSessionIdleTimeout": 1209600,
    "accessCodeLifespan": 60,
    "accessCodeLifespanUserAction": 300,
    "accessCodeLifespanLogin": 1800,
    "internationalizationEnabled": true,
    "supportedLocales": ["en"],
    "defaultLocale": "en",
    "eventsEnabled": true,
    "eventsListeners": ["jboss-logging"],
    "enabledEventTypes": ["LOGIN", "LOGIN_ERROR", "LOGOUT", "REGISTER", "REGISTER_ERROR", "CODE_TO_TOKEN", "CODE_TO_TOKEN_ERROR"],
    "adminEventsEnabled": true,
    "adminEventsDetailsEnabled": true
}
EOF
{
    "realm": "${INTERNAL_REALM}",
    "enabled": true,
    "displayName": "Tesseract Admin Portal",
    "registrationAllowed": false,
    "loginWithEmailAllowed": true,
    "resetPasswordAllowed": true,
    "bruteForceProtected": true,
    "passwordPolicy": "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(2) and notUsername"
}
EOF2

    log_success "Internal realm configured"

    # Create admin client
    create_admin_client "$token"

    # Create admin-bff client (confidential)
    create_admin_bff_client "$token"

    # Create realm roles
    create_internal_roles "$token"

    # Create test admin user
    create_internal_test_user "$token"
}

create_admin_client() {
    local token=$1

    log_info "Creating admin web client..."

    local client_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients?clientId=admin-web" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "admin-web",
        "name": "Tesseract Admin Dashboard",
        "description": "Admin dashboard web application",
        "enabled": true,
        "publicClient": true,
        "standardFlowEnabled": true,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": false,
        "serviceAccountsEnabled": false,
        "protocol": "openid-connect",
        "rootUrl": "'${ADMIN_URL}'",
        "baseUrl": "'${ADMIN_URL}'",
        "redirectUris": [
            "'${ADMIN_URL}'/*",
            "http://localhost:3001/*",
            "http://localhost:4201/*"
        ],
        "webOrigins": [
            "'${ADMIN_URL}'",
            "http://localhost:3001",
            "http://localhost:4201"
        ],
        "attributes": {
            "pkce.code.challenge.method": "S256",
            "post.logout.redirect.uris": "'${ADMIN_URL}'/*##http://localhost:3001/*"
        },
        "defaultClientScopes": ["openid", "email", "profile", "roles"],
        "optionalClientScopes": ["offline_access"]
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    log_success "Admin web client configured"
}

create_admin_bff_client() {
    local token=$1

    log_info "Creating admin BFF client (confidential)..."

    local client_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients?clientId=admin-bff" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local client_config='{
        "clientId": "admin-bff",
        "name": "Admin Backend-for-Frontend",
        "description": "Confidential client for admin BFF server",
        "enabled": true,
        "publicClient": false,
        "standardFlowEnabled": true,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": true,
        "serviceAccountsEnabled": true,
        "authorizationServicesEnabled": false,
        "protocol": "openid-connect",
        "redirectUris": [
            "'${ADMIN_URL}'/api/auth/callback/*",
            "http://localhost:3001/api/auth/callback/*"
        ],
        "webOrigins": [
            "'${ADMIN_URL}'",
            "http://localhost:3001"
        ],
        "attributes": {
            "pkce.code.challenge.method": "S256",
            "client.secret.creation.time": "0"
        },
        "defaultClientScopes": ["openid", "email", "profile", "roles"],
        "optionalClientScopes": ["offline_access"]
    }'

    if [ -n "$client_id" ]; then
        curl -s -X PUT "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients/${client_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    else
        curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$client_config"
    fi

    # Get client secret
    client_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients?clientId=admin-bff" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id')

    local secret=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/clients/${client_id}/client-secret" \
        -H "Authorization: Bearer $token" | jq -r '.value')

    log_success "Admin BFF client configured"
    log_info "Client Secret: $secret (save this for admin-bff configuration)"
}

create_internal_roles() {
    local token=$1

    log_info "Creating internal realm roles..."

    local roles=("super_admin" "tenant_admin" "admin" "staff" "employee" "readonly")

    for role in "${roles[@]}"; do
        local role_exists=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/roles/${role}" \
            -H "Authorization: Bearer $token" -o /dev/null -w "%{http_code}")

        if [ "$role_exists" != "200" ]; then
            curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/roles" \
                -H "Authorization: Bearer $token" \
                -H "Content-Type: application/json" \
                -d "{\"name\": \"${role}\", \"description\": \"${role} role for internal users\"}"
            log_info "  Created role: $role"
        else
            log_info "  Role exists: $role"
        fi
    done

    log_success "Internal roles configured"
}

create_internal_test_user() {
    local token=$1

    log_info "Creating test admin user..."

    # Check if user exists
    local user_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users?email=samyak.rout@gmail.com" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    if [ -n "$user_id" ]; then
        log_warn "User samyak.rout@gmail.com already exists, updating..."

        curl -s -X PUT "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users/${user_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d '{
                "enabled": true,
                "emailVerified": true,
                "firstName": "Samyak",
                "lastName": "Rout",
                "attributes": {
                    "tenant_id": ["00000000-0000-0000-0000-000000000001"],
                    "tenant_slug": ["primary"]
                }
            }'
    else
        # Create user
        curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d '{
                "username": "samyak.rout@gmail.com",
                "email": "samyak.rout@gmail.com",
                "enabled": true,
                "emailVerified": true,
                "firstName": "Samyak",
                "lastName": "Rout",
                "attributes": {
                    "tenant_id": ["00000000-0000-0000-0000-000000000001"],
                    "tenant_slug": ["primary"]
                },
                "credentials": [{
                    "type": "password",
                    "value": "***REMOVED***",
                    "temporary": false
                }]
            }'

        user_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users?email=samyak.rout@gmail.com" \
            -H "Authorization: Bearer $token" | jq -r '.[0].id')
    fi

    # Set password
    curl -s -X PUT "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users/${user_id}/reset-password" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "password",
            "value": "***REMOVED***",
            "temporary": false
        }'

    # Assign super_admin role
    local role_id=$(curl -s -X GET "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/roles/super_admin" \
        -H "Authorization: Bearer $token" | jq -r '.id')

    curl -s -X POST "${INTERNAL_KEYCLOAK_URL}/admin/realms/${INTERNAL_REALM}/users/${user_id}/role-mappings/realm" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "[{\"id\": \"${role_id}\", \"name\": \"super_admin\"}]"

    log_success "Admin test user created: samyak.rout@gmail.com / ***REMOVED*** (super_admin)"
}

# -----------------------------------------------------------------------------
# Create Protocol Mappers for Custom Claims
# -----------------------------------------------------------------------------
create_protocol_mappers() {
    local keycloak_url=$1
    local realm=$2
    local token=$3
    local client_name=$4

    log_info "Creating protocol mappers for $client_name..."

    # Get client ID
    local client_id=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients?clientId=${client_name}" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    if [ -z "$client_id" ]; then
        log_error "Client $client_name not found"
        return 1
    fi

    # Tenant ID mapper
    curl -s -X POST "${keycloak_url}/admin/realms/${realm}/clients/${client_id}/protocol-mappers/models" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "tenant_id",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-usermodel-attribute-mapper",
            "config": {
                "claim.name": "tenant_id",
                "user.attribute": "tenant_id",
                "jsonType.label": "String",
                "id.token.claim": "true",
                "access.token.claim": "true",
                "userinfo.token.claim": "true"
            }
        }' 2>/dev/null || true

    # Tenant Slug mapper
    curl -s -X POST "${keycloak_url}/admin/realms/${realm}/clients/${client_id}/protocol-mappers/models" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "tenant_slug",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-usermodel-attribute-mapper",
            "config": {
                "claim.name": "tenant_slug",
                "user.attribute": "tenant_slug",
                "jsonType.label": "String",
                "id.token.claim": "true",
                "access.token.claim": "true",
                "userinfo.token.claim": "true"
            }
        }' 2>/dev/null || true

    # User ID mapper (sub claim)
    curl -s -X POST "${keycloak_url}/admin/realms/${realm}/clients/${client_id}/protocol-mappers/models" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "user_id",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-usersessionmodel-note-mapper",
            "config": {
                "claim.name": "user_id",
                "user.session.note": "USER_ID",
                "jsonType.label": "String",
                "id.token.claim": "true",
                "access.token.claim": "true"
            }
        }' 2>/dev/null || true

    log_success "Protocol mappers created for $client_name"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
main() {
    echo "============================================="
    echo "KEYCLOAK REALM SETUP FOR TESSERACT HUB"
    echo "============================================="
    echo ""

    # Check prerequisites
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi

    # Parse arguments
    case "${1:-all}" in
        customer)
            create_customer_realm
            ;;
        internal)
            create_internal_realm
            ;;
        all)
            create_customer_realm
            echo ""
            create_internal_realm
            ;;
        *)
            echo "Usage: $0 [customer|internal|all]"
            exit 1
            ;;
    esac

    echo ""
    echo "============================================="
    log_success "Keycloak realm setup complete!"
    echo "============================================="
    echo ""
    echo "Test Credentials:"
    echo "  Customer Portal: samyak.rout@gmail.com / ***REMOVED***"
    echo "  Admin Portal:    samyak.rout@gmail.com / ***REMOVED*** (super_admin)"
    echo ""
    echo "Customer IDP: $CUSTOMER_KEYCLOAK_URL/realms/$CUSTOMER_REALM"
    echo "Internal IDP: $INTERNAL_KEYCLOAK_URL/realms/$INTERNAL_REALM"
}

main "$@"
