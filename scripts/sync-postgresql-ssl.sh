#!/bin/bash
#
# Sync PostgreSQL SSL certificates from GCP Secret Manager to Kubernetes
#
# Each PostgreSQL namespace gets its own unique certificates.
#
# Usage: ./sync-postgresql-ssl.sh -e <environment> [-p <project-id>]
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ENVIRONMENT=""
PROJECT_ID=""

# Namespace to suffix mapping (bash 3.2 compatible)
NAMESPACES="postgresql-marketplace:marketplace postgresql-global:global postgresql-bookkeeping:bookkeeping"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    head -8 "$0" | tail -6 | sed 's/^#//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -p|--project) PROJECT_ID="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ENVIRONMENT" ]]; then
    log_error "Environment required. Use -e devtest|staging|prod"
    exit 1
fi

if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    [[ -z "$PROJECT_ID" ]] && { log_error "Could not detect GCP project"; exit 1; }
fi

log_info "Syncing PostgreSQL SSL certificates"
log_info "Environment: $ENVIRONMENT | Project: $PROJECT_ID"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for entry in $NAMESPACES; do
    namespace="${entry%%:*}"
    suffix="${entry#*:}"
    log_info "Syncing certificates for $namespace (suffix: $suffix)..."

    # Fetch namespace-specific certificates from GCP
    gcloud secrets versions access latest \
        --secret="${ENVIRONMENT}-postgresql-${suffix}-server-cert" \
        --project="$PROJECT_ID" > "$TMPDIR/server.crt"

    gcloud secrets versions access latest \
        --secret="${ENVIRONMENT}-postgresql-${suffix}-server-key" \
        --project="$PROJECT_ID" > "$TMPDIR/server.key"

    gcloud secrets versions access latest \
        --secret="${ENVIRONMENT}-postgresql-${suffix}-ca-cert" \
        --project="$PROJECT_ID" > "$TMPDIR/ca.crt"

    # Ensure namespace exists
    kubectl create namespace "$namespace" 2>/dev/null || true

    # Create or update secret
    kubectl create secret generic postgresql-ssl-certs \
        --from-file=server.crt="$TMPDIR/server.crt" \
        --from-file=server.key="$TMPDIR/server.key" \
        --from-file=ca.crt="$TMPDIR/ca.crt" \
        -n "$namespace" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "Secret synced to $namespace"
done

echo ""
log_success "All SSL certificates synced!"
echo ""
echo "To apply changes, restart PostgreSQL pods:"
for entry in $NAMESPACES; do
    namespace="${entry%%:*}"
    echo "  kubectl rollout restart statefulset postgresql -n $namespace"
done
