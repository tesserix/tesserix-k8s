#!/bin/bash
# =============================================================================
# GrowthBook Initialization Script
# Creates admin account, organization, SDK connections, and feature flags
# Stores credentials in GCP Secret Manager and GitHub Secrets
# =============================================================================
set -e

# =============================================================================
# Configuration (can be overridden by environment variables)
# =============================================================================
ENVIRONMENT="${ENVIRONMENT:-devtest}"
COMPANY_NAME="${COMPANY_NAME:-Tesserix}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@tesserix.app}"
ADMIN_NAME="${ADMIN_NAME:-Tesserix Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"  # Will be generated if not provided

# GrowthBook URLs based on environment
case "$ENVIRONMENT" in
  "devtest")
    GROWTHBOOK_HOST="${GROWTHBOOK_HOST:-https://dev-growthbook.tesserix.app}"
    GROWTHBOOK_INTERNAL_HOST="${GROWTHBOOK_INTERNAL_HOST:-http://growthbook.growthbook.svc.cluster.local:3100}"
    GCP_PROJECT="${GCP_PROJECT:-tesseract-devtest}"
    ;;
  "prod"|"production")
    GROWTHBOOK_HOST="${GROWTHBOOK_HOST:-https://growthbook.tesserix.app}"
    GROWTHBOOK_INTERNAL_HOST="${GROWTHBOOK_INTERNAL_HOST:-http://growthbook.growthbook.svc.cluster.local:3100}"
    GCP_PROJECT="${GCP_PROJECT:-tesseract-prod}"
    ;;
  *)
    echo "ERROR: Unknown environment: $ENVIRONMENT"
    echo "Valid environments: devtest, prod"
    exit 1
    ;;
esac

# GCP Secret Manager names
GCP_SECRET_ADMIN_PASSWORD="growthbook-admin-password"
GCP_SECRET_SDK_KEY="growthbook-sdk-key"
GCP_SECRET_API_KEY="growthbook-api-key"

# GitHub repository for secrets
GITHUB_REPO="${GITHUB_REPO:-tesserix/tesserix-k8s}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

generate_password() {
  # Generate a secure random password
  openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

wait_for_growthbook() {
  local host="$1"
  local max_retries="${2:-60}"
  local retry_interval="${3:-5}"
  local retry_count=0

  log_info "Waiting for GrowthBook at $host..."

  until curl -sf "${host}/healthcheck" > /dev/null 2>&1; do
    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $max_retries ]; then
      log_error "GrowthBook not ready after ${max_retries} retries"
      return 1
    fi
    echo "  Waiting... (attempt $retry_count/$max_retries)"
    sleep $retry_interval
  done

  log_success "GrowthBook is healthy!"
  return 0
}

# =============================================================================
# GrowthBook API Functions
# =============================================================================
register_admin() {
  local host="$1"
  local email="$2"
  local password="$3"
  local name="$4"

  log_info "Registering admin user: $email"

  local result
  result=$(curl -sf -X POST "${host}/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\",\"name\":\"${name}\"}" 2>&1) || true

  if echo "$result" | grep -q '"token"\|"status":200\|"email"'; then
    log_success "Admin user registered successfully"
    return 0
  elif echo "$result" | grep -q "already exists\|duplicate"; then
    log_warning "Admin user already exists"
    return 0
  else
    log_warning "Registration response: $result"
    return 0  # Continue anyway, might already exist
  fi
}

login() {
  local host="$1"
  local email="$2"
  local password="$3"

  log_info "Logging in as $email..."

  local result
  result=$(curl -sf -X POST "${host}/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\"}")

  TOKEN=$(echo "$result" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

  if [ -z "$TOKEN" ]; then
    log_error "Failed to get authentication token"
    echo "Login result: $result"
    return 1
  fi

  log_success "Successfully authenticated!"
  echo "$TOKEN"
}

get_or_create_organization() {
  local host="$1"
  local token="$2"
  local org_name="$3"

  log_info "Getting/creating organization: $org_name"

  # Get user info to find existing organization
  local user_info
  user_info=$(curl -sf "${host}/user" \
    -H "Authorization: Bearer ${token}")

  ORG_ID=$(echo "$user_info" | grep -o '"organizations":\[{"id":"org_[^"]*"' | grep -o 'org_[^"]*' | head -1)

  if [ -z "$ORG_ID" ]; then
    log_info "No organization found, creating one..."

    local create_result
    create_result=$(curl -sf -X POST "${host}/organization" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "{\"company\":\"${org_name}\"}" 2>&1) || true

    # Re-fetch user info
    user_info=$(curl -sf "${host}/user" \
      -H "Authorization: Bearer ${token}")

    ORG_ID=$(echo "$user_info" | grep -o '"organizations":\[{"id":"org_[^"]*"' | grep -o 'org_[^"]*' | head -1)
  fi

  if [ -z "$ORG_ID" ]; then
    log_error "Failed to get or create organization"
    return 1
  fi

  log_success "Organization ID: $ORG_ID"
  echo "$ORG_ID"
}

create_sdk_connection() {
  local host="$1"
  local token="$2"
  local org_id="$3"
  local name="$4"
  local env="$5"

  log_info "Creating SDK connection: $name ($env)"

  # Check if SDK connection already exists
  local existing
  existing=$(curl -sf "${host}/sdk-connections" \
    -H "Authorization: Bearer ${token}" \
    -H "x-organization: ${org_id}")

  local existing_key
  existing_key=$(echo "$existing" | grep -o "\"name\":\"${name}\"[^}]*\"key\":\"sdk-[^\"]*\"" | grep -o 'sdk-[^"]*' | head -1)

  if [ -n "$existing_key" ]; then
    log_warning "SDK connection '$name' already exists with key: $existing_key"
    echo "$existing_key"
    return 0
  fi

  # Create new SDK connection
  local result
  result=$(curl -sf -X POST "${host}/sdk-connections" \
    -H "Authorization: Bearer ${token}" \
    -H "x-organization: ${org_id}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"languages\": [\"javascript\", \"nocode-other\", \"react\", \"nodejs\"],
      \"environment\": \"${env}\",
      \"encryptPayload\": false,
      \"includeVisualExperiments\": true,
      \"includeDraftExperiments\": false,
      \"includeExperimentNames\": true
    }")

  local sdk_key
  sdk_key=$(echo "$result" | grep -o '"key":"sdk-[^"]*"' | cut -d'"' -f4)

  if [ -z "$sdk_key" ]; then
    log_error "Failed to create SDK connection"
    echo "Result: $result"
    return 1
  fi

  log_success "Created SDK connection with key: $sdk_key"
  echo "$sdk_key"
}

create_api_key() {
  local host="$1"
  local token="$2"
  local org_id="$3"
  local description="$4"

  log_info "Creating API key: $description"

  # Check existing API keys
  local existing
  existing=$(curl -sf "${host}/keys" \
    -H "Authorization: Bearer ${token}" \
    -H "x-organization: ${org_id}" 2>/dev/null) || existing=""

  if echo "$existing" | grep -q "\"description\":\"${description}\""; then
    log_warning "API key '$description' already exists"
    # Can't retrieve existing key value, so just return success
    return 0
  fi

  # Create new API key
  local result
  result=$(curl -sf -X POST "${host}/keys" \
    -H "Authorization: Bearer ${token}" \
    -H "x-organization: ${org_id}" \
    -H "Content-Type: application/json" \
    -d "{
      \"description\": \"${description}\",
      \"environment\": \"\",
      \"encryptSDK\": false,
      \"role\": \"admin\"
    }")

  local api_key
  api_key=$(echo "$result" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -z "$api_key" ]; then
    # Try alternate response format
    api_key=$(echo "$result" | grep -o '"secret":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi

  if [ -n "$api_key" ]; then
    log_success "Created API key"
    echo "$api_key"
  else
    log_warning "API key created but couldn't extract value"
  fi
}

create_feature() {
  local host="$1"
  local token="$2"
  local org_id="$3"
  local feature_id="$4"
  local description="$5"
  local default_value="$6"
  local tags="$7"

  # Create feature
  local result
  result=$(curl -sf -X POST "${host}/feature" \
    -H "Authorization: Bearer ${token}" \
    -H "x-organization: ${org_id}" \
    -H "Content-Type: application/json" \
    -d "{
      \"id\": \"${feature_id}\",
      \"description\": \"${description}\",
      \"valueType\": \"boolean\",
      \"defaultValue\": \"${default_value}\",
      \"tags\": ${tags},
      \"environments\": {
        \"dev\": {\"enabled\": true, \"rules\": []},
        \"production\": {\"enabled\": true, \"rules\": []}
      }
    }" 2>&1)

  if echo "$result" | grep -q '"id"'; then
    echo "  Created: $feature_id"
  elif echo "$result" | grep -q "already exists\|duplicate"; then
    echo "  Exists: $feature_id"
  else
    echo "  Failed: $feature_id - $result"
  fi
}

# =============================================================================
# Secret Management Functions
# =============================================================================
store_gcp_secret() {
  local secret_name="$1"
  local secret_value="$2"
  local project="$3"

  log_info "Storing secret in GCP Secret Manager: $secret_name"

  # Check if secret exists
  if gcloud secrets describe "$secret_name" --project="$project" &>/dev/null; then
    # Add new version
    echo -n "$secret_value" | gcloud secrets versions add "$secret_name" \
      --project="$project" \
      --data-file=- 2>/dev/null
    log_success "Updated existing secret: $secret_name"
  else
    # Create new secret
    echo -n "$secret_value" | gcloud secrets create "$secret_name" \
      --project="$project" \
      --replication-policy="automatic" \
      --data-file=- 2>/dev/null
    log_success "Created new secret: $secret_name"
  fi
}

store_github_secret() {
  local secret_name="$1"
  local secret_value="$2"
  local repo="$3"
  local env="${4:-}"

  log_info "Storing secret in GitHub: $secret_name"

  if [ -n "$env" ]; then
    gh secret set "$secret_name" \
      --repo "$repo" \
      --env "$env" \
      --body "$secret_value" 2>/dev/null
    log_success "Stored GitHub environment secret: $secret_name ($env)"
  else
    gh secret set "$secret_name" \
      --repo "$repo" \
      --body "$secret_value" 2>/dev/null
    log_success "Stored GitHub repository secret: $secret_name"
  fi
}

# =============================================================================
# Feature Flags Definition
# =============================================================================
create_all_features() {
  local host="$1"
  local token="$2"
  local org_id="$3"

  log_info "Creating feature flags..."

  # Search Features
  create_feature "$host" "$token" "$org_id" "global_search_enabled" "Enable global search functionality across the platform" "true" '["search"]'
  create_feature "$host" "$token" "$org_id" "search_autocomplete" "Enable search autocomplete suggestions" "true" '["search"]'
  create_feature "$host" "$token" "$org_id" "search_typo_tolerance" "Enable typo tolerance in search" "true" '["search"]'
  create_feature "$host" "$token" "$org_id" "advanced_search_filters" "Enable advanced search filters" "false" '["search"]'

  # E-commerce Features
  create_feature "$host" "$token" "$org_id" "multi_currency" "Enable multi-currency support" "true" '["ecommerce"]'
  create_feature "$host" "$token" "$org_id" "guest_checkout" "Allow guest checkout without account" "true" '["ecommerce"]'
  create_feature "$host" "$token" "$org_id" "wishlist_enabled" "Enable wishlist functionality" "true" '["ecommerce"]'
  create_feature "$host" "$token" "$org_id" "product_reviews" "Enable product reviews and ratings" "true" '["ecommerce"]'
  create_feature "$host" "$token" "$org_id" "product_compare" "Enable product comparison feature" "false" '["ecommerce"]'
  create_feature "$host" "$token" "$org_id" "bulk_ordering" "Enable bulk ordering functionality" "false" '["ecommerce"]'

  # Payment Features
  create_feature "$host" "$token" "$org_id" "apple_pay" "Enable Apple Pay payment method" "false" '["payments"]'
  create_feature "$host" "$token" "$org_id" "google_pay" "Enable Google Pay payment method" "false" '["payments"]'
  create_feature "$host" "$token" "$org_id" "buy_now_pay_later" "Enable Buy Now Pay Later options" "false" '["payments"]'
  create_feature "$host" "$token" "$org_id" "subscription_payments" "Enable subscription-based payments" "false" '["payments"]'

  # UI/UX Features
  create_feature "$host" "$token" "$org_id" "dark_mode" "Enable dark mode theme option" "false" '["ui"]'
  create_feature "$host" "$token" "$org_id" "new_checkout_flow" "Enable new checkout flow design" "false" '["ui"]'
  create_feature "$host" "$token" "$org_id" "product_quick_view" "Enable product quick view modal" "true" '["ui"]'
  create_feature "$host" "$token" "$org_id" "infinite_scroll" "Enable infinite scroll on product lists" "false" '["ui"]'
  create_feature "$host" "$token" "$org_id" "sticky_header" "Enable sticky navigation header" "true" '["ui"]'

  # Admin Features
  create_feature "$host" "$token" "$org_id" "analytics_dashboard_v2" "Enable new analytics dashboard version" "false" '["admin"]'
  create_feature "$host" "$token" "$org_id" "bulk_product_edit" "Enable bulk product editing" "true" '["admin"]'
  create_feature "$host" "$token" "$org_id" "ai_product_descriptions" "Enable AI-generated product descriptions" "false" '["admin"]'
  create_feature "$host" "$token" "$org_id" "inventory_alerts" "Enable inventory alert notifications" "true" '["admin"]'

  # Mobile Features
  create_feature "$host" "$token" "$org_id" "biometric_auth" "Enable biometric authentication" "false" '["mobile"]'
  create_feature "$host" "$token" "$org_id" "push_notifications" "Enable push notifications" "true" '["mobile"]'
  create_feature "$host" "$token" "$org_id" "offline_mode" "Enable offline mode support" "false" '["mobile"]'
  create_feature "$host" "$token" "$org_id" "ar_product_preview" "Enable AR product preview" "false" '["mobile"]'

  # Performance Features
  create_feature "$host" "$token" "$org_id" "image_lazy_loading" "Enable lazy loading for images" "true" '["performance"]'
  create_feature "$host" "$token" "$org_id" "service_worker" "Enable service worker for caching" "false" '["performance"]'
  create_feature "$host" "$token" "$org_id" "prefetch_enabled" "Enable link prefetching" "true" '["performance"]'

  # Multi-tenant Features
  create_feature "$host" "$token" "$org_id" "tenant_custom_domain" "Enable custom domain per tenant" "true" '["tenant"]'
  create_feature "$host" "$token" "$org_id" "tenant_custom_theme" "Enable custom theme per tenant" "true" '["tenant"]'
  create_feature "$host" "$token" "$org_id" "tenant_analytics" "Enable tenant-specific analytics" "true" '["tenant"]'
  create_feature "$host" "$token" "$org_id" "white_label_enabled" "Enable white-label branding" "false" '["tenant"]'

  log_success "Feature flags creation completed!"
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
  echo "=============================================="
  echo "  GrowthBook Initialization Script"
  echo "  Environment: $ENVIRONMENT"
  echo "  Company: $COMPANY_NAME"
  echo "=============================================="
  echo ""

  # Determine which host to use
  local gb_host="$GROWTHBOOK_HOST"

  # If running in-cluster, use internal host
  if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
    gb_host="$GROWTHBOOK_INTERNAL_HOST"
    log_info "Running in-cluster, using internal host: $gb_host"
  fi

  # Wait for GrowthBook
  if ! wait_for_growthbook "$gb_host"; then
    exit 1
  fi

  # Generate password if not provided
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(generate_password)
    log_info "Generated admin password"
  fi

  # Register admin user
  register_admin "$gb_host" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "$ADMIN_NAME"

  # Login
  TOKEN=$(login "$gb_host" "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  if [ -z "$TOKEN" ]; then
    exit 1
  fi

  # Get/create organization
  ORG_ID=$(get_or_create_organization "$gb_host" "$TOKEN" "$COMPANY_NAME")
  if [ -z "$ORG_ID" ]; then
    exit 1
  fi

  # Create SDK connections
  SDK_KEY_PROD=$(create_sdk_connection "$gb_host" "$TOKEN" "$ORG_ID" "Tesserix Platform - Production" "production")
  SDK_KEY_DEV=$(create_sdk_connection "$gb_host" "$TOKEN" "$ORG_ID" "Tesserix Platform - Development" "dev")

  # Use production SDK key as the primary one
  SDK_KEY="${SDK_KEY_PROD:-$SDK_KEY_DEV}"

  # Create API key for backend services
  API_KEY=$(create_api_key "$gb_host" "$TOKEN" "$ORG_ID" "Tesserix Backend Services - $ENVIRONMENT")

  # Create all feature flags
  create_all_features "$gb_host" "$TOKEN" "$ORG_ID"

  echo ""
  echo "=============================================="
  echo "  Storing Credentials"
  echo "=============================================="

  # Store in GCP Secret Manager (if gcloud is available)
  if command -v gcloud &> /dev/null; then
    log_info "Storing credentials in GCP Secret Manager..."
    store_gcp_secret "${GCP_SECRET_ADMIN_PASSWORD}-${ENVIRONMENT}" "$ADMIN_PASSWORD" "$GCP_PROJECT" || true
    store_gcp_secret "${GCP_SECRET_SDK_KEY}-${ENVIRONMENT}" "$SDK_KEY" "$GCP_PROJECT" || true
    if [ -n "$API_KEY" ]; then
      store_gcp_secret "${GCP_SECRET_API_KEY}-${ENVIRONMENT}" "$API_KEY" "$GCP_PROJECT" || true
    fi
  else
    log_warning "gcloud not found, skipping GCP Secret Manager storage"
  fi

  # Store in GitHub Secrets (if gh is available)
  if command -v gh &> /dev/null; then
    log_info "Storing credentials in GitHub Secrets..."

    # Convert environment name to uppercase for GitHub secrets
    local env_upper
    env_upper=$(echo "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')

    store_github_secret "GROWTHBOOK_ADMIN_PASSWORD_${env_upper}" "$ADMIN_PASSWORD" "$GITHUB_REPO" || true
    store_github_secret "GROWTHBOOK_SDK_KEY_${env_upper}" "$SDK_KEY" "$GITHUB_REPO" || true
    if [ -n "$API_KEY" ]; then
      store_github_secret "GROWTHBOOK_API_KEY_${env_upper}" "$API_KEY" "$GITHUB_REPO" || true
    fi
  else
    log_warning "gh CLI not found, skipping GitHub Secrets storage"
  fi


  echo ""
  echo "=============================================="
  echo "  Initialization Complete!"
  echo "=============================================="
  echo ""
  echo "Environment:     $ENVIRONMENT"
  echo "GrowthBook URL:  $GROWTHBOOK_HOST"
  echo "Organization:    $COMPANY_NAME ($ORG_ID)"
  echo ""
  echo "Admin Credentials:"
  echo "  Email:    $ADMIN_EMAIL"
  echo "  Password: $ADMIN_PASSWORD"
  echo ""
  echo "SDK Keys:"
  echo "  Production: $SDK_KEY_PROD"
  echo "  Development: $SDK_KEY_DEV"
  echo ""
  if [ -n "$API_KEY" ]; then
    echo "API Key: $API_KEY"
    echo ""
  fi
  echo "Next Steps:"
  echo "  1. Visit $GROWTHBOOK_HOST and login with the admin credentials"
  echo "  2. Update feature-flags-service with the SDK key"
  echo "  3. Configure admin panel with NEXT_PUBLIC_GROWTHBOOK_CLIENT_KEY=$SDK_KEY"
  echo ""
}

# Run main function
main "$@"
