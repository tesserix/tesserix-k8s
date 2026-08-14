#!/usr/bin/env bash
# =============================================================================
# Sealed Secrets Generator Script
# =============================================================================
# This script generates unique strong secrets and seals them using kubeseal
# for each environment (devtest, pilot, prod).
#
# Prerequisites:
# - kubeseal CLI installed (https://github.com/bitnami-labs/sealed-secrets)
# - openssl for password generation
# - The sealed secrets certificates exist in sealedsecret/{env}/sealed-secrets.crt
#
# Usage:
#   ./scripts/generate-secrets.sh [environment] [namespace] [secret-type]
#
# Examples:
#   ./scripts/generate-secrets.sh devtest infrastructure all
#   ./scripts/generate-secrets.sh pilot global postgresql
#   ./scripts/generate-secrets.sh prod marketplace all
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SEALEDSECRET_DIR="${ROOT_DIR}/sealedsecret"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT="${1:-}"
NAMESPACE="${2:-all}"
SECRET_TYPE="${3:-all}"

# =============================================================================
# Helper Functions
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

# Generate a cryptographically strong password
generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c "${length}"
}

# Generate a base64 encoded secret
generate_base64_secret() {
    local length="${1:-32}"
    openssl rand -base64 "${length}" | tr -d '\n'
}

# Generate a hex secret (useful for encryption keys)
generate_hex_secret() {
    local bytes="${1:-32}"
    openssl rand -hex "${bytes}"
}

# Check if kubeseal is installed
check_kubeseal() {
    if ! command -v kubeseal &> /dev/null; then
        log_error "kubeseal is not installed. Install from: https://github.com/bitnami-labs/sealed-secrets"
        exit 1
    fi
}

# Get the certificate path for an environment
get_cert_path() {
    local env="$1"
    echo "${SEALEDSECRET_DIR}/${env}/sealed-secrets.crt"
}

# Seal a secret using kubeseal
seal_secret() {
    local env="$1"
    local input_file="$2"
    local output_file="$3"

    local cert_path
    cert_path=$(get_cert_path "${env}")

    if [[ ! -f "${cert_path}" ]]; then
        log_error "Certificate not found: ${cert_path}"
        return 1
    fi

    kubeseal --cert "${cert_path}" \
        --format yaml \
        < "${input_file}" \
        > "${output_file}"

    log_success "Sealed secret created: ${output_file}"
}

# =============================================================================
# Secret Generation Functions
# =============================================================================

# Generate PostgreSQL secrets for a namespace
generate_postgresql_secrets() {
    local env="$1"
    local ns="$2"
    local output_dir="${SEALEDSECRET_DIR}/${env}/${ns}"

    mkdir -p "${output_dir}"

    local password
    password=$(generate_password 24)
    local replication_password
    replication_password=$(generate_password 24)

    # Create plain secret
    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-password
  namespace: postgresql-${ns}
type: Opaque
stringData:
  postgres-password: "${password}"
  password: "${password}"
  replication-password: "${replication_password}"
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/postgresql-password.yaml"
    rm -f "${temp_file}"

    log_info "PostgreSQL password for ${ns}: ${password} (save this!)"
}

# Generate GHCR (GitHub Container Registry) secrets
generate_ghcr_secret() {
    local env="$1"
    local ns="$2"
    local output_dir="${SEALEDSECRET_DIR}/${env}/${ns}"

    mkdir -p "${output_dir}"

    # These should come from environment variables or be prompted
    local username="${GHCR_USERNAME:-}"
    local token="${GHCR_TOKEN:-}"

    if [[ -z "${username}" || -z "${token}" ]]; then
        log_warn "GHCR_USERNAME and GHCR_TOKEN not set, using placeholders"
        username="PLACEHOLDER_USERNAME"
        token="PLACEHOLDER_TOKEN"
    fi

    local dockerconfig
    dockerconfig=$(echo -n "{\"auths\":{\"ghcr.io\":{\"username\":\"${username}\",\"password\":\"${token}\",\"auth\":\"$(echo -n "${username}:${token}" | base64)\"}}}" | base64)

    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-secret
  namespace: ${ns}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${dockerconfig}
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/ghcr-secret.yaml"
    rm -f "${temp_file}"
}

# Generate JWT secrets
generate_jwt_secret() {
    local env="$1"
    local ns="$2"
    local output_dir="${SEALEDSECRET_DIR}/${env}/${ns}"

    mkdir -p "${output_dir}"

    local jwt_secret
    jwt_secret=$(generate_hex_secret 32)
    local jwt_refresh_secret
    jwt_refresh_secret=$(generate_hex_secret 32)

    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: jwt-secret
  namespace: ${ns}
type: Opaque
stringData:
  jwt-secret: "${jwt_secret}"
  jwt-refresh-secret: "${jwt_refresh_secret}"
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/jwt-secret.yaml"
    rm -f "${temp_file}"

    log_info "JWT secret for ${ns}: ${jwt_secret} (save this!)"
}

# Generate Keycloak secrets
generate_keycloak_secrets() {
    local env="$1"
    local output_dir="${SEALEDSECRET_DIR}/${env}/infrastructure"

    mkdir -p "${output_dir}"

    local admin_password
    admin_password=$(generate_password 24)
    local db_password
    db_password=$(generate_password 24)
    local redis_password
    redis_password=$(generate_password 24)

    local temp_file
    temp_file=$(mktemp)

    # Admin credentials
    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-password
  namespace: identity
type: Opaque
stringData:
  admin-password: "${admin_password}"
EOF
    seal_secret "${env}" "${temp_file}" "${output_dir}/keycloak-admin-password.yaml"

    # DB credentials
    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-password
  namespace: identity
type: Opaque
stringData:
  password: "${db_password}"
EOF
    seal_secret "${env}" "${temp_file}" "${output_dir}/keycloak-db-password.yaml"

    # Redis credentials
    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-redis-password
  namespace: identity
type: Opaque
stringData:
  redis-password: "${redis_password}"
EOF
    seal_secret "${env}" "${temp_file}" "${output_dir}/keycloak-redis-password.yaml"

    rm -f "${temp_file}"

    log_info "Keycloak admin password: ${admin_password}"
    log_info "Keycloak DB password: ${db_password}"
    log_info "Keycloak Redis password: ${redis_password}"
}

# Generate Typesense secrets
generate_typesense_secrets() {
    local env="$1"
    local output_dir="${SEALEDSECRET_DIR}/${env}/infrastructure"

    mkdir -p "${output_dir}"

    local api_key
    api_key=$(generate_hex_secret 32)

    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: typesense-secrets
  namespace: typesense
type: Opaque
stringData:
  api-key: "${api_key}"
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/typesense-secrets.yaml"
    rm -f "${temp_file}"

    log_info "Typesense API key: ${api_key}"
}

# Generate Email infrastructure secrets
generate_email_secrets() {
    local env="$1"
    local output_dir="${SEALEDSECRET_DIR}/${env}/infrastructure"

    mkdir -p "${output_dir}"

    local mysql_root_password
    mysql_root_password=$(generate_password 24)
    local mysql_password
    mysql_password=$(generate_password 24)
    local postal_signing_key
    postal_signing_key=$(generate_hex_secret 32)
    local postal_smtp_password
    postal_smtp_password=$(generate_password 16)
    local mautic_admin_password
    mautic_admin_password=$(generate_password 16)
    local mautic_db_password
    mautic_db_password=$(generate_password 24)
    local rabbitmq_password
    rabbitmq_password=$(generate_password 24)

    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: email-infrastructure-secrets
  namespace: email
type: Opaque
stringData:
  mysql-root-password: "${mysql_root_password}"
  mysql-password: "${mysql_password}"
  postal-signing-key: "${postal_signing_key}"
  postal-smtp-password: "${postal_smtp_password}"
  mautic-admin-password: "${mautic_admin_password}"
  mautic-db-password: "${mautic_db_password}"
  rabbitmq-password: "${rabbitmq_password}"
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/email-infrastructure-secrets.yaml"
    rm -f "${temp_file}"

    log_info "Email secrets generated for ${env}"
}

# Generate GrowthBook secrets
generate_growthbook_secrets() {
    local env="$1"
    local output_dir="${SEALEDSECRET_DIR}/${env}/infrastructure"

    mkdir -p "${output_dir}"

    local api_secret
    api_secret=$(generate_hex_secret 32)
    local encryption_key
    encryption_key=$(generate_hex_secret 32)

    local temp_file
    temp_file=$(mktemp)

    cat > "${temp_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: growthbook-secrets
  namespace: growthbook
type: Opaque
stringData:
  api-secret: "${api_secret}"
  encryption-key: "${encryption_key}"
EOF

    seal_secret "${env}" "${temp_file}" "${output_dir}/growthbook-secrets.yaml"
    rm -f "${temp_file}"

    log_info "GrowthBook secrets generated for ${env}"
}

# Generate all infrastructure secrets
generate_all_infrastructure_secrets() {
    local env="$1"

    log_info "Generating all infrastructure secrets for ${env}..."

    generate_keycloak_secrets "${env}"
    generate_typesense_secrets "${env}"
    generate_email_secrets "${env}"
    generate_growthbook_secrets "${env}"

    log_success "All infrastructure secrets generated for ${env}"
}

# Generate all namespace secrets
generate_namespace_secrets() {
    local env="$1"
    local ns="$2"

    log_info "Generating secrets for namespace: ${ns}"

    generate_postgresql_secrets "${env}" "${ns}"
    generate_jwt_secret "${env}" "${ns}"
    generate_ghcr_secret "${env}" "${ns}"
}

# Generate all secrets for an environment
generate_all_secrets() {
    local env="$1"

    log_info "=========================================="
    log_info "Generating ALL secrets for: ${env}"
    log_info "=========================================="

    # Infrastructure secrets
    generate_all_infrastructure_secrets "${env}"

    # Per-namespace secrets
    local namespaces=("global" "marketplace" "bookkeeping" "hms" "fanzone" "homechef")

    for ns in "${namespaces[@]}"; do
        generate_namespace_secrets "${env}" "${ns}"
    done

    log_success "All secrets generated for ${env}"
    log_warn "IMPORTANT: Save the generated passwords securely!"
}

# Create kustomization files for sealed secrets
create_kustomization_files() {
    local env="$1"

    log_info "Creating kustomization files for ${env}..."

    # Main kustomization
    cat > "${SEALEDSECRET_DIR}/${env}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - infrastructure
  - global
  - marketplace
  - bookkeeping
  # - hms       # Enable when ready
  # - fanzone   # Enable when ready
  # - homechef  # Enable when ready
EOF

    # Infrastructure kustomization
    cat > "${SEALEDSECRET_DIR}/${env}/infrastructure/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - keycloak-admin-password.yaml
  - keycloak-db-password.yaml
  - keycloak-redis-password.yaml
  - typesense-secrets.yaml
  - email-infrastructure-secrets.yaml
  - growthbook-secrets.yaml
EOF

    # Per-namespace kustomizations
    local namespaces=("global" "marketplace" "bookkeeping" "hms" "fanzone" "homechef")

    for ns in "${namespaces[@]}"; do
        mkdir -p "${SEALEDSECRET_DIR}/${env}/${ns}"
        cat > "${SEALEDSECRET_DIR}/${env}/${ns}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - postgresql-password.yaml
  - jwt-secret.yaml
  - ghcr-secret.yaml
EOF
    done

    log_success "Kustomization files created for ${env}"
}

# =============================================================================
# Main
# =============================================================================

usage() {
    cat <<EOF
Sealed Secrets Generator Script

Usage: $0 <environment> [namespace] [secret-type]

Arguments:
  environment   Required. One of: devtest, pilot, prod
  namespace     Optional. One of: infrastructure, global, marketplace, bookkeeping, hms, fanzone, homechef, all
                Default: all
  secret-type   Optional. One of: postgresql, jwt, ghcr, keycloak, typesense, email, growthbook, all
                Default: all

Environment Variables:
  GHCR_USERNAME  GitHub Container Registry username
  GHCR_TOKEN     GitHub Container Registry personal access token

Examples:
  $0 devtest                          # Generate all secrets for devtest
  $0 pilot infrastructure             # Generate infrastructure secrets for pilot
  $0 prod global postgresql           # Generate PostgreSQL secrets for prod/global
  $0 prod all                         # Generate all secrets for prod

EOF
    exit 1
}

main() {
    check_kubeseal

    if [[ -z "${ENVIRONMENT}" ]]; then
        usage
    fi

    if [[ ! "${ENVIRONMENT}" =~ ^(devtest|pilot|prod)$ ]]; then
        log_error "Invalid environment: ${ENVIRONMENT}"
        usage
    fi

    local cert_path
    cert_path=$(get_cert_path "${ENVIRONMENT}")

    if [[ ! -f "${cert_path}" ]]; then
        log_error "Certificate not found: ${cert_path}"
        log_error "Please ensure the sealed-secrets.crt file exists for the environment"
        exit 1
    fi

    log_info "Using certificate: ${cert_path}"

    # Create kustomization files
    create_kustomization_files "${ENVIRONMENT}"

    if [[ "${NAMESPACE}" == "all" ]]; then
        generate_all_secrets "${ENVIRONMENT}"
    elif [[ "${NAMESPACE}" == "infrastructure" ]]; then
        generate_all_infrastructure_secrets "${ENVIRONMENT}"
    else
        if [[ "${SECRET_TYPE}" == "all" ]]; then
            generate_namespace_secrets "${ENVIRONMENT}" "${NAMESPACE}"
        else
            case "${SECRET_TYPE}" in
                postgresql)
                    generate_postgresql_secrets "${ENVIRONMENT}" "${NAMESPACE}"
                    ;;
                jwt)
                    generate_jwt_secret "${ENVIRONMENT}" "${NAMESPACE}"
                    ;;
                ghcr)
                    generate_ghcr_secret "${ENVIRONMENT}" "${NAMESPACE}"
                    ;;
                *)
                    log_error "Unknown secret type: ${SECRET_TYPE}"
                    usage
                    ;;
            esac
        fi
    fi

    log_success "Secret generation complete!"
    log_warn "Don't forget to update GitHub Secrets with the generated values!"
}

main "$@"
