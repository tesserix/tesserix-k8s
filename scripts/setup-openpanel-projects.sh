#!/usr/bin/env bash
# =============================================================================
# setup-openpanel-projects.sh
#
# Automates creating OpenPanel projects for all frontend apps and patches
# ArgoCD Application manifests with the resulting client IDs.
#
# Prerequisites:
#   1. A root-type client must exist in each OpenPanel environment.
#      Create one manually in the OpenPanel dashboard:
#        Settings > Clients > New Client > type: root
#      Root credentials live in OpenBao. Export the selected environment's
#      credentials from its approved read-only identity before running setup.
#      Production: openpanel/app/openpanel-root-client-{id,secret}.
#      Development requires separate reviewed OpenBao paths and grants.
#
#   2. jq must be installed (brew install jq)
#
# Usage:
#   ./scripts/setup-openpanel-projects.sh devtest
#   ./scripts/setup-openpanel-projects.sh prod
#   ./scripts/setup-openpanel-projects.sh all
#
# What it does:
#   1. Creates 3 projects (admin, storefront, tenant-onboarding) via Manage API
#   2. Extracts the auto-generated client IDs from each response
#   3. Patches the ArgoCD Application YAML files with real client IDs
#   4. Stores product client IDs in OpenBao with a temporary scoped writer
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- Configuration ----
declare -A ENV_API_URLS=(
  [devtest]="https://dev-analytics.tesserix.app"
  [prod]="https://analytics.tesserix.app"
)

declare -A ENV_DOMAINS=(
  [devtest]="tesserix.app"
  [prod]="mark8ly.com"
)

# Projects to create (name -> CORS domains per env)
APPS=("admin" "storefront" "tenant-onboarding")

declare -A APP_DOMAINS_DEVTEST=(
  [admin]="https://dev-admin.tesserix.app"
  [storefront]="https://dev-store.tesserix.app"
  [tenant-onboarding]="https://dev-onboarding.tesserix.app"
)

declare -A APP_DOMAINS_PROD=(
  [admin]="https://admin.mark8ly.com"
  [storefront]="https://store.mark8ly.com"
  [tenant-onboarding]="https://mark8ly.com"
)

# ArgoCD file paths (relative to repo root)
declare -A ARGOCD_PATHS=(
  [devtest]="argocd/devtest/apps/marketplace"
  [prod]="argocd/prod/apps/marketplace"
)

# ---- Helpers ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_deps() {
  for cmd in jq curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd is required but not installed."
      exit 1
    fi
  done
  [[ -n "${BAO_TOKEN:-}" ]] || { log_error "A temporary scoped BAO_TOKEN is required for product identifiers"; exit 1; }
}

# ---- Core Functions ----

# Root credentials must be supplied from the selected OpenBao environment.
get_root_credentials() {
  local env="$1"

  # Try environment variables first
  local id_var="OPENPANEL_${env^^}_ROOT_CLIENT_ID"
  local secret_var="OPENPANEL_${env^^}_ROOT_CLIENT_SECRET"

  if [[ -n "${!id_var:-}" && -n "${!secret_var:-}" ]]; then
    ROOT_CLIENT_ID="${!id_var}"
    ROOT_CLIENT_SECRET="${!secret_var}"
    log_info "Using root credentials from environment variables"
    return 0
  fi

  log_error "Root credentials from OpenBao are required for '$env'."
  log_error "Export OPENPANEL_${env^^}_ROOT_CLIENT_ID and OPENPANEL_${env^^}_ROOT_CLIENT_SECRET using the approved environment reader."
  return 1
}

# Create a project via the Manage API
# Returns: client_id on stdout
create_project() {
  local api_url="$1"
  local project_name="$2"
  local domain="$3"

  log_info "Creating project '$project_name' at $api_url ..."

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "${api_url}/manage/projects" \
    -H "Content-Type: application/json" \
    -H "openpanel-client-id: ${ROOT_CLIENT_ID}" \
    -H "openpanel-client-secret: ${ROOT_CLIENT_SECRET}" \
    -d "$(jq -n \
      --arg name "$project_name" \
      --arg domain "$domain" \
      '{
        name: $name,
        domain: $domain,
        cors: [$domain],
        types: ["website"]
      }'
    )")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    local client_id
    client_id=$(echo "$body" | jq -r '.data.client.id // empty')

    if [[ -z "$client_id" ]]; then
      log_error "Project created but no client ID in response"
      echo "$body" | jq . 2>/dev/null || echo "$body"
      return 1
    fi

    local project_id
    project_id=$(echo "$body" | jq -r '.data.id // empty')
    log_ok "Project '$project_name' created (project: $project_id, client: $client_id)"

    echo "$client_id"
    return 0
  elif [[ "$http_code" == "409" ]]; then
    log_warn "Project '$project_name' already exists. Fetching existing client..."

    # List projects and find ours
    local projects_response
    projects_response=$(curl -s "${api_url}/manage/projects" \
      -H "openpanel-client-id: ${ROOT_CLIENT_ID}" \
      -H "openpanel-client-secret: ${ROOT_CLIENT_SECRET}")

    local project_id
    project_id=$(echo "$projects_response" | jq -r ".data[] | select(.name == \"$project_name\") | .id" 2>/dev/null || echo "")

    if [[ -z "$project_id" ]]; then
      # Try slug-based match
      local slug
      slug=$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      project_id=$(echo "$projects_response" | jq -r ".data[] | select(.id == \"$slug\") | .id" 2>/dev/null || echo "")
    fi

    if [[ -n "$project_id" ]]; then
      # List clients for this project
      local clients_response
      clients_response=$(curl -s "${api_url}/manage/clients?projectId=${project_id}" \
        -H "openpanel-client-id: ${ROOT_CLIENT_ID}" \
        -H "openpanel-client-secret: ${ROOT_CLIENT_SECRET}")

      local client_id
      client_id=$(echo "$clients_response" | jq -r '.data[0].id // empty' 2>/dev/null)

      if [[ -n "$client_id" ]]; then
        log_ok "Found existing client: $client_id"
        echo "$client_id"
        return 0
      fi
    fi

    log_error "Could not find existing client for '$project_name'"
    return 1
  else
    log_error "Failed to create project '$project_name' (HTTP $http_code)"
    echo "$body" | jq . 2>/dev/null || echo "$body"
    return 1
  fi
}

# Patch an ArgoCD Application YAML file to replace placeholder client ID
patch_argocd_file() {
  local file="$1"
  local client_id="$2"

  if [[ ! -f "$file" ]]; then
    log_warn "ArgoCD file not found: $file"
    return 1
  fi

  if grep -q '<to-be-set-after-creating-project>' "$file"; then
    sed -i.bak 's/<to-be-set-after-creating-project>/'"$client_id"'/' "$file"
    rm -f "${file}.bak"
    log_ok "Patched $file with client ID: $client_id"
  elif grep -q "NEXT_PUBLIC_OPENPANEL_CLIENT_ID" "$file"; then
    log_info "File already has a client ID set: $file"
  else
    log_warn "No OPENPANEL_CLIENT_ID placeholder found in $file"
  fi
}

# Root credentials and product client IDs use OpenBao. Supply a <=15m BAO_TOKEN with create/read on
# the exact mark8ly[-development]/app/mark8ly-openpanel-<app>-client-id paths,
# then revoke the token after setup. Different existing values fail closed.
store_client_id_openbao() {
  local env="$1"
  local app="$2"
  local client_id="$3"
  printf '%s' "$client_id" | python3 "${SCRIPT_DIR}/store-openpanel-client-id.py" \
    --environment "$env" --app "$app"
}

# ---- Main ----

setup_environment() {
  local env="$1"
  local api_url="${ENV_API_URLS[$env]}"

  echo ""
  echo "============================================="
  echo "  Setting up OpenPanel projects: ${env}"
  echo "  API: ${api_url}"
  echo "============================================="
  echo ""

  # Get root credentials
  if ! get_root_credentials "$env"; then
    return 1
  fi

  # Create projects and collect client IDs
  declare -A CLIENT_IDS

  for app in "${APPS[@]}"; do
    local domain
    if [[ "$env" == "devtest" ]]; then
      domain="${APP_DOMAINS_DEVTEST[$app]}"
    else
      domain="${APP_DOMAINS_PROD[$app]}"
    fi

    local project_name="Tesserix ${app^} (${env})"
    local client_id
    client_id=$(create_project "$api_url" "$project_name" "$domain") || {
      log_error "Failed to create project for '$app'. Skipping."
      continue
    }

    CLIENT_IDS[$app]="$client_id"

    # Patch ArgoCD file
    local argocd_dir="${REPO_ROOT}/${ARGOCD_PATHS[$env]}"
    local argocd_file="${argocd_dir}/${app}.yaml"
    patch_argocd_file "$argocd_file" "$client_id"

    # Store the product identifier in OpenBao.
    store_client_id_openbao "$env" "$app" "$client_id"
  done

  echo ""
  echo "---------------------------------------------"
  echo "  Summary for ${env}:"
  echo "---------------------------------------------"
  for app in "${APPS[@]}"; do
    if [[ -n "${CLIENT_IDS[$app]:-}" ]]; then
      echo "  ${app}: ${CLIENT_IDS[$app]}"
    else
      echo "  ${app}: FAILED"
    fi
  done
  echo "---------------------------------------------"
  echo ""
}

usage() {
  echo "Usage: $0 <environment>"
  echo ""
  echo "  environment:  devtest | prod | all"
  echo ""
  echo "Prerequisites:"
  echo "  Export root client credentials:"
  echo "    export OPENPANEL_DEVTEST_ROOT_CLIENT_ID=<uuid>"
  echo "    export OPENPANEL_DEVTEST_ROOT_CLIENT_SECRET=<sec_...>"
  echo "    export OPENPANEL_PROD_ROOT_CLIENT_ID=<uuid>"
  echo "    export OPENPANEL_PROD_ROOT_CLIENT_SECRET=<sec_...>"
  echo ""
  echo "  Or store them in GCP Secret Manager (script will auto-fetch)."
  echo ""
  echo "How to get a root client:"
  echo "  1. Log into OpenPanel dashboard"
  echo "  2. Go to Settings > Clients"
  echo "  3. Create a new client with type: root"
  echo "  4. Save the client ID and secret"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  check_deps

  local target="$1"

  case "$target" in
    devtest)
      setup_environment "devtest"
      ;;
    prod)
      setup_environment "prod"
      ;;
    all)
      setup_environment "devtest"
      setup_environment "prod"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown environment: $target"
      usage
      exit 1
      ;;
  esac

  echo ""
  log_ok "Done! Commit the patched ArgoCD files and push to trigger sync."
  echo ""
  echo "Next steps:"
  echo "  1. git diff ${REPO_ROOT}/argocd/"
  echo "  2. git add -A && git commit -m 'chore: set OpenPanel client IDs'"
  echo "  3. git push  (ArgoCD auto-syncs and rolling-restarts pods)"
}

main "$@"
