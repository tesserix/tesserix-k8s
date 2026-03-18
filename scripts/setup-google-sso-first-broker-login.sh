#!/bin/bash
# =============================================================================
# Setup Google SSO First Broker Login Flow for Identity-Internal Realm
# =============================================================================
# Creates the "Auto Create-or-Link First Broker Login" authentication flow
# and configures the Google IDP to use it.
#
# This flow handles BOTH new users (onboarding) and existing users (admin login):
#
#   Auto Create-or-Link First Broker Login (top-level)
#   ├── Create User If Unique               (ALTERNATIVE)  ← new users from onboarding
#   └── Auto-Link Existing Account           (ALTERNATIVE, sub-flow)
#       ├── Detect existing broker user      (REQUIRED)
#       └── Automatically set existing user  (REQUIRED)     ← existing users from admin login
#
# It also adds onboarding redirect URIs to the marketplace-dashboard client.
#
# Prerequisites:
#   - kubectl access to the cluster with identity-internal namespace
#   - curl, jq installed
#
# Usage:
#   # Via port-forward (default):
#   ./setup-google-sso-first-broker-login.sh
#
#   # Via external URL:
#   KEYCLOAK_URL=https://devtest-internal-idp.tesserix.app \
#   KEYCLOAK_REALM=tesserix-internal \
#     ./setup-google-sso-first-broker-login.sh
#
#   # With custom Keycloak admin credentials (skips kubectl):
#   KEYCLOAK_URL=https://devtest-internal-idp.tesserix.app \
#   KEYCLOAK_REALM=tesserix-internal \
#   KEYCLOAK_ADMIN_USER=admin \
#   KEYCLOAK_ADMIN_PASSWORD=<password> \
#     ./setup-google-sso-first-broker-login.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration with sensible defaults
KC_NAMESPACE="${KC_NAMESPACE:-identity-internal}"
KEYCLOAK_URL="${KEYCLOAK_URL:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-tesserix-internal}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-marketplace-dashboard}"
BASE_DOMAIN="${BASE_DOMAIN:-tesserix.app}"
PORT_FORWARD_PID=""

FLOW_ALIAS="Auto Create-or-Link First Broker Login"
SUBFLOW_ALIAS="Auto-Link Existing Account"

# =============================================================================
# Helpers
# =============================================================================

cleanup() {
  if [ -n "$PORT_FORWARD_PID" ]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    log_info "Stopped port-forward (PID: $PORT_FORWARD_PID)"
  fi
}
trap cleanup EXIT

check_prerequisites() {
  log_info "Checking prerequisites..."
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd is required but not installed"
      exit 1
    fi
  done
  log_success "Prerequisites met"
}

setup_connection() {
  if [ -n "$KEYCLOAK_URL" ]; then
    log_info "Using external Keycloak URL: $KEYCLOAK_URL"
  else
    log_info "Setting up port-forward to Keycloak in $KC_NAMESPACE..."
    kubectl port-forward -n "$KC_NAMESPACE" svc/keycloak 9080:8080 &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 3
    KEYCLOAK_URL="http://localhost:9080"
    log_success "Port-forward active on :9080"
  fi

  # Get admin credentials from K8s secrets if not provided
  if [ -z "$KEYCLOAK_ADMIN_USER" ] || [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    log_info "Reading admin credentials from K8s secret..."
    KEYCLOAK_ADMIN_USER=$(kubectl get secret -n "$KC_NAMESPACE" keycloak-admin-credentials \
      -o jsonpath='{.data.username}' | base64 -d)
    KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret -n "$KC_NAMESPACE" keycloak-admin-credentials \
      -o jsonpath='{.data.password}' | base64 -d)
  fi
}

get_admin_token() {
  log_info "Authenticating with Keycloak..."
  local response
  response=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN_USER}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}")

  KC_TOKEN=$(echo "$response" | jq -r '.access_token')
  if [ -z "$KC_TOKEN" ] || [ "$KC_TOKEN" = "null" ]; then
    log_error "Failed to obtain admin token"
    exit 1
  fi
  log_success "Authenticated"
}

kc_api() {
  # Usage: kc_api GET /path
  #        kc_api POST /path '{"json":"body"}'
  #        kc_api PUT /path '{"json":"body"}'
  local method="$1" path="$2" body="${3:-}"
  local url="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}${path}"
  local args=(-s -X "$method" -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "$url"
}

kc_api_status() {
  local method="$1" path="$2" body="${3:-}"
  local url="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}${path}"
  local args=(-s -o /dev/null -w "%{http_code}" -X "$method" -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "$url"
}

url_encode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))"
}

# =============================================================================
# Step 1: Create the Authentication Flow
# =============================================================================

create_flow() {
  local flow_encoded
  flow_encoded=$(url_encode "$FLOW_ALIAS")

  log_info "Checking if flow '$FLOW_ALIAS' exists..."
  local existing
  existing=$(kc_api GET "/authentication/flows" | jq -r --arg alias "$FLOW_ALIAS" '.[] | select(.alias == $alias) | .id')

  if [ -n "$existing" ]; then
    log_warn "Flow '$FLOW_ALIAS' already exists (id: $existing). Skipping creation."
    return 0
  fi

  log_info "Creating top-level flow: $FLOW_ALIAS"
  local status
  status=$(kc_api_status POST "/authentication/flows" '{
    "alias": "'"$FLOW_ALIAS"'",
    "description": "Creates new users during onboarding OR auto-links existing users during admin login via Google SSO",
    "providerId": "basic-flow",
    "topLevel": true,
    "builtIn": false
  }')

  if [ "$status" != "201" ]; then
    log_error "Failed to create flow (HTTP $status)"
    exit 1
  fi
  log_success "Created flow: $FLOW_ALIAS"
}

# =============================================================================
# Step 2: Add idp-create-user-if-unique Execution (ALTERNATIVE)
# =============================================================================

add_create_user_execution() {
  local flow_encoded
  flow_encoded=$(url_encode "$FLOW_ALIAS")

  # Check if already added
  local executions
  executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
  local existing
  existing=$(echo "$executions" | jq -r '.[] | select(.providerId == "idp-create-user-if-unique") | .id')

  if [ -n "$existing" ]; then
    log_info "idp-create-user-if-unique already exists. Ensuring ALTERNATIVE..."
    kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
      '{"id":"'"$existing"'","requirement":"ALTERNATIVE"}' >/dev/null
    log_success "idp-create-user-if-unique is ALTERNATIVE"
    return 0
  fi

  log_info "Adding idp-create-user-if-unique execution..."
  local status
  status=$(kc_api_status POST "/authentication/flows/${flow_encoded}/executions/execution" \
    '{"provider":"idp-create-user-if-unique"}')

  if [ "$status" != "201" ]; then
    log_error "Failed to add idp-create-user-if-unique (HTTP $status)"
    exit 1
  fi

  # Set to ALTERNATIVE
  executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
  local exec_id
  exec_id=$(echo "$executions" | jq -r '.[] | select(.providerId == "idp-create-user-if-unique") | .id')
  kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
    '{"id":"'"$exec_id"'","requirement":"ALTERNATIVE"}' >/dev/null

  log_success "Added idp-create-user-if-unique (ALTERNATIVE)"
}

# =============================================================================
# Step 3: Create "Auto-Link Existing Account" Sub-flow (ALTERNATIVE)
# =============================================================================

create_subflow() {
  local flow_encoded subflow_encoded
  flow_encoded=$(url_encode "$FLOW_ALIAS")
  subflow_encoded=$(url_encode "$SUBFLOW_ALIAS")

  # Check if sub-flow already exists
  local executions
  executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
  local existing
  existing=$(echo "$executions" | jq -r --arg name "$SUBFLOW_ALIAS" '.[] | select(.displayName == $name) | .id')

  if [ -n "$existing" ]; then
    log_info "Sub-flow '$SUBFLOW_ALIAS' already exists. Ensuring ALTERNATIVE..."
    kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
      '{"id":"'"$existing"'","requirement":"ALTERNATIVE","authenticationFlow":true}' >/dev/null
    log_success "Sub-flow is ALTERNATIVE"
    return 0
  fi

  log_info "Creating sub-flow: $SUBFLOW_ALIAS"
  local status
  status=$(kc_api_status POST "/authentication/flows/${flow_encoded}/executions/flow" '{
    "alias": "'"$SUBFLOW_ALIAS"'",
    "description": "Detects and auto-links existing users during admin Google login",
    "provider": "basic-flow",
    "type": "basic-flow"
  }')

  if [ "$status" != "201" ]; then
    log_error "Failed to create sub-flow (HTTP $status)"
    exit 1
  fi

  # Set to ALTERNATIVE
  executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
  local subflow_exec_id
  subflow_exec_id=$(echo "$executions" | jq -r --arg name "$SUBFLOW_ALIAS" '.[] | select(.displayName == $name) | .id')
  kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
    '{"id":"'"$subflow_exec_id"'","requirement":"ALTERNATIVE","authenticationFlow":true}' >/dev/null

  log_success "Created sub-flow: $SUBFLOW_ALIAS (ALTERNATIVE)"
}

# =============================================================================
# Step 4: Add Executions to Sub-flow (REQUIRED)
# =============================================================================

add_subflow_executions() {
  local flow_encoded subflow_encoded
  flow_encoded=$(url_encode "$FLOW_ALIAS")
  subflow_encoded=$(url_encode "$SUBFLOW_ALIAS")

  for provider in "idp-detect-existing-broker-user" "idp-auto-link"; do
    # Check if already added
    local executions
    executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
    local existing
    existing=$(echo "$executions" | jq -r --arg p "$provider" '.[] | select(.providerId == $p and .level == 1) | .id')

    if [ -n "$existing" ]; then
      log_info "$provider already exists in sub-flow. Ensuring REQUIRED..."
      kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
        '{"id":"'"$existing"'","requirement":"REQUIRED"}' >/dev/null
      log_success "$provider is REQUIRED"
      continue
    fi

    log_info "Adding $provider to sub-flow..."
    local status
    status=$(kc_api_status POST "/authentication/flows/${subflow_encoded}/executions/execution" \
      '{"provider":"'"$provider"'"}')

    if [ "$status" != "201" ]; then
      log_error "Failed to add $provider (HTTP $status)"
      exit 1
    fi

    # Set to REQUIRED
    executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
    local exec_id
    exec_id=$(echo "$executions" | jq -r --arg p "$provider" '.[] | select(.providerId == $p and .level == 1) | .id')
    kc_api_status PUT "/authentication/flows/${flow_encoded}/executions" \
      '{"id":"'"$exec_id"'","requirement":"REQUIRED"}' >/dev/null

    log_success "Added $provider (REQUIRED)"
  done
}

# =============================================================================
# Step 5: Update Google IDP to Use the New Flow
# =============================================================================

update_google_idp() {
  log_info "Checking Google IDP configuration..."
  local idp_config
  idp_config=$(kc_api GET "/identity-provider/instances/google")

  if echo "$idp_config" | jq -e '.alias' &>/dev/null; then
    local current_flow
    current_flow=$(echo "$idp_config" | jq -r '.firstBrokerLoginFlowAlias')

    if [ "$current_flow" = "$FLOW_ALIAS" ]; then
      log_info "Google IDP already uses '$FLOW_ALIAS'"
      return 0
    fi

    log_info "Updating Google IDP firstBrokerLoginFlowAlias: $current_flow → $FLOW_ALIAS"
    local updated
    updated=$(echo "$idp_config" | jq --arg flow "$FLOW_ALIAS" '.firstBrokerLoginFlowAlias = $flow')
    local status
    status=$(kc_api_status PUT "/identity-provider/instances/google" "$updated")

    if [ "$status" != "204" ]; then
      log_error "Failed to update Google IDP (HTTP $status)"
      exit 1
    fi
    log_success "Google IDP now uses: $FLOW_ALIAS"
  else
    log_warn "Google IDP not found in realm $KEYCLOAK_REALM — skipping"
    log_warn "Run configure-google-idp.sh first to create the Google IDP"
  fi
}

# =============================================================================
# Step 6: Add Onboarding Redirect URIs to Client
# =============================================================================

add_onboarding_redirect_uris() {
  log_info "Checking redirect URIs for client: $KEYCLOAK_CLIENT_ID"

  local clients
  clients=$(kc_api GET "/clients?clientId=${KEYCLOAK_CLIENT_ID}&first=0&max=1")
  local client_uuid
  client_uuid=$(echo "$clients" | jq -r '.[0].id // empty')

  if [ -z "$client_uuid" ]; then
    log_warn "Client $KEYCLOAK_CLIENT_ID not found — skipping redirect URI update"
    return 0
  fi

  local client_config
  client_config=$(kc_api GET "/clients/${client_uuid}")
  local current_uris
  current_uris=$(echo "$client_config" | jq -r '.redirectUris[]' 2>/dev/null || true)

  # URIs to add
  local new_uris=(
    "https://onboarding.${BASE_DOMAIN}/*"
    "https://onboarding.${BASE_DOMAIN}/auth/callback"
    "https://*-onboarding.${BASE_DOMAIN}/*"
    "https://*-onboarding.${BASE_DOMAIN}/auth/callback"
    "https://*.${BASE_DOMAIN}/*"
    "http://localhost:3001/*"
    "http://localhost:3001/auth/callback"
    "http://localhost:3000/*"
  )

  local to_add=()
  for uri in "${new_uris[@]}"; do
    if ! echo "$current_uris" | grep -qF "$uri"; then
      to_add+=("$uri")
    fi
  done

  if [ ${#to_add[@]} -eq 0 ]; then
    log_info "All onboarding redirect URIs already present"
    return 0
  fi

  log_info "Adding ${#to_add[@]} redirect URI(s)..."

  # Build jq filter to add URIs
  local jq_filter='.redirectUris += ['
  for i in "${!to_add[@]}"; do
    [ "$i" -gt 0 ] && jq_filter+=","
    jq_filter+='"'"${to_add[$i]}"'"'
  done
  jq_filter+='] | .redirectUris |= unique'

  local updated
  updated=$(echo "$client_config" | jq "$jq_filter")
  local status
  status=$(kc_api_status PUT "/clients/${client_uuid}" "$updated")

  if [ "$status" != "204" ]; then
    log_error "Failed to update client redirect URIs (HTTP $status)"
    exit 1
  fi

  for uri in "${to_add[@]}"; do
    log_info "  + $uri"
  done
  log_success "Redirect URIs updated"
}

# =============================================================================
# Step 7: Enable registrationEmailAsUsername on Realm
# =============================================================================
# Ensures Keycloak always populates the email field when creating users via IDP.
# Without this, users created by tenant-service may have email=null if username
# is set to their email address, which breaks idp-detect-existing-broker-user
# (it matches by email, not username).

enable_registration_email_as_username() {
  log_info "Checking registrationEmailAsUsername on realm $KEYCLOAK_REALM..."

  local realm_config
  realm_config=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}")
  local current
  current=$(echo "$realm_config" | jq -r '.registrationEmailAsUsername // false')

  if [ "$current" = "true" ]; then
    log_info "registrationEmailAsUsername already enabled"
    return 0
  fi

  log_info "Setting registrationEmailAsUsername=true..."
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}" \
    -d '{"registrationEmailAsUsername": true}')

  if [ "$status" != "204" ]; then
    log_error "Failed to set registrationEmailAsUsername (HTTP $status)"
    exit 1
  fi
  log_success "registrationEmailAsUsername enabled"
}

# =============================================================================
# Step 8: Repair Users with Null/Empty Email
# =============================================================================
# Scans all users in the realm and fixes any that have null/empty email by
# copying their username (which is typically the email address). This handles
# users created by tenant-service before registrationEmailAsUsername was enabled.

repair_null_email_users() {
  log_info "Scanning for users with null/empty email..."

  local users
  users=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?first=0&max=500")

  local total
  total=$(echo "$users" | jq 'length')
  log_info "Found $total users in realm"

  local null_users
  null_users=$(echo "$users" | jq -r '.[] | select(.email == null or .email == "") | "\(.id)|\(.username)"')

  if [ -z "$null_users" ]; then
    log_success "All users have email set — no repairs needed"
    return 0
  fi

  local count=0
  echo "$null_users" | while IFS='|' read -r uid uname; do
    log_info "Repairing user: $uname (id: $uid) → setting email=$uname"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
      -H "Authorization: Bearer $KC_TOKEN" \
      -H "Content-Type: application/json" \
      "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${uid}" \
      -d "{\"email\": \"${uname}\", \"emailVerified\": true}")

    if [ "$status" = "204" ]; then
      log_success "  Fixed: $uname"
    else
      log_warn "  Failed to fix $uname (HTTP $status)"
    fi
    count=$((count + 1))
  done

  log_success "Email repair complete"
}

# =============================================================================
# Step 9: Verify Final State
# =============================================================================

verify() {
  log_info "Verifying configuration..."
  local flow_encoded
  flow_encoded=$(url_encode "$FLOW_ALIAS")

  echo ""
  echo "Flow structure:"
  local executions
  executions=$(kc_api GET "/authentication/flows/${flow_encoded}/executions")
  echo "$executions" | jq -r '.[] | "  \("  " * .level)[\(.requirement)] \(.displayName) (\(.providerId // "sub-flow"))"'

  echo ""
  echo "Google IDP:"
  kc_api GET "/identity-provider/instances/google" 2>/dev/null | \
    jq '{alias, enabled, firstBrokerLoginFlowAlias}' 2>/dev/null || echo "  (not configured)"

  echo ""
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "============================================="
echo "Google SSO First Broker Login Flow Setup"
echo "============================================="
echo "Realm: $KEYCLOAK_REALM"
echo "Base Domain: $BASE_DOMAIN"
echo ""

check_prerequisites
setup_connection
get_admin_token
create_flow
add_create_user_execution
create_subflow
add_subflow_executions
update_google_idp
add_onboarding_redirect_uris
enable_registration_email_as_username
repair_null_email_users
verify

echo "============================================="
log_success "Setup complete!"
echo "============================================="
echo ""
echo "What this configured:"
echo "  1. Created authentication flow: $FLOW_ALIAS"
echo "     - New user (onboarding): idp-create-user-if-unique"
echo "     - Existing user (admin login): detect + auto-link"
echo "  2. Updated Google IDP to use the new flow"
echo "  3. Added onboarding redirect URIs to $KEYCLOAK_CLIENT_ID"
echo "  4. Enabled registrationEmailAsUsername on realm"
echo "  5. Repaired any users with null/empty email"
echo ""
echo "Custom domain redirect URIs are managed automatically by"
echo "custom-domain-service when a tenant registers a custom domain."
echo ""
