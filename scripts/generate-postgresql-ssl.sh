#!/bin/bash
#
# PostgreSQL SSL Certificate Generator and GCP Secret Manager Uploader
#
# Generates unique SSL certificates for each PostgreSQL namespace with a shared CA.
# Certificates are stored in GCP Secret Manager and synced to Kubernetes.
#
# Usage: ./generate-postgresql-ssl.sh -e <environment> [-p <project-id>] [--dry-run]
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ENVIRONMENT=""
PROJECT_ID=""
VALIDITY_DAYS=365
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/../.ssl-certs"

# PostgreSQL namespaces that need unique certificates
NAMESPACES=("postgresql-marketplace" "postgresql-global" "postgresql-bookkeeping")

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    head -10 "$0" | tail -8 | sed 's/^#//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
        -p|--project) PROJECT_ID="$2"; shift 2 ;;
        -d|--days) VALIDITY_DAYS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
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

mkdir -p "$CERT_DIR"
log_info "Environment: $ENVIRONMENT | Project: $PROJECT_ID | Validity: $VALIDITY_DAYS days"

# Generate shared CA certificate
generate_ca() {
    log_info "Generating shared CA certificate..."
    openssl genrsa -out "$CERT_DIR/ca.key" 4096
    openssl req -new -x509 -days "$VALIDITY_DAYS" -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.crt" -subj "/CN=PostgreSQL-CA-${ENVIRONMENT}/O=Tesserix/OU=Database/C=US"
    log_success "CA certificate generated"
}

# Generate server certificate for a specific namespace
generate_server_cert() {
    local namespace=$1
    log_info "Generating server certificate for $namespace..."

    local cert_dir="$CERT_DIR/$namespace"
    mkdir -p "$cert_dir"

    # Generate private key
    openssl genrsa -out "$cert_dir/server.key" 2048

    # Build SAN list specific to this namespace
    local san="DNS:postgresql,DNS:postgresql.$namespace,DNS:postgresql.$namespace.svc,DNS:postgresql.$namespace.svc.cluster.local"
    san="$san,DNS:postgresql-headless,DNS:postgresql-headless.$namespace,DNS:postgresql-headless.$namespace.svc.cluster.local"
    san="$san,DNS:postgresql-0,DNS:postgresql-0.postgresql-headless,DNS:postgresql-0.postgresql-headless.$namespace.svc.cluster.local"
    san="$san,DNS:localhost"

    # Create extension file
    cat > "$cert_dir/ext.cnf" << EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no
[req_dn]
CN = postgresql
O = Tesserix
OU = Database-$namespace
C = US
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
EOF

    # Generate CSR and sign with CA
    openssl req -new -key "$cert_dir/server.key" -out "$cert_dir/server.csr" -config "$cert_dir/ext.cnf"
    openssl x509 -req -days "$VALIDITY_DAYS" -in "$cert_dir/server.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$cert_dir/server.crt" -extensions v3_req -extfile "$cert_dir/ext.cnf"

    # Copy CA cert
    cp "$CERT_DIR/ca.crt" "$cert_dir/ca.crt"

    # Set permissions
    chmod 600 "$cert_dir/server.key"
    chmod 644 "$cert_dir/server.crt" "$cert_dir/ca.crt"

    # Verify
    openssl verify -CAfile "$CERT_DIR/ca.crt" "$cert_dir/server.crt" > /dev/null
    log_success "Certificate for $namespace generated and verified"
}

# Upload certificates to GCP Secret Manager
upload_to_gcp() {
    local namespace=$1
    local cert_dir="$CERT_DIR/$namespace"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Dry run - skipping GCP upload for $namespace"
        return
    fi

    log_info "Uploading certificates for $namespace to GCP..."

    # Extract namespace suffix for secret naming (e.g., postgresql-marketplace -> marketplace)
    local suffix=${namespace#postgresql-}

    for cert_type in "server-cert:server.crt" "server-key:server.key" "ca-cert:ca.crt"; do
        local secret_name="${ENVIRONMENT}-postgresql-${suffix}-${cert_type%%:*}"
        local file_name="${cert_type#*:}"

        if gcloud secrets describe "$secret_name" --project="$PROJECT_ID" &>/dev/null; then
            gcloud secrets versions add "$secret_name" --project="$PROJECT_ID" \
                --data-file="$cert_dir/$file_name" --quiet
        else
            gcloud secrets create "$secret_name" --project="$PROJECT_ID" \
                --replication-policy="automatic" --data-file="$cert_dir/$file_name" --quiet
        fi
    done
    log_success "Certificates uploaded for $namespace"
}

# Cleanup temporary files
cleanup() {
    log_info "Cleaning up..."
    find "$CERT_DIR" -name "*.csr" -o -name "*.cnf" -o -name "*.srl" | xargs rm -f 2>/dev/null || true
}

# Main
main() {
    log_info "Starting PostgreSQL SSL certificate generation..."

    generate_ca

    for namespace in "${NAMESPACES[@]}"; do
        generate_server_cert "$namespace"
        upload_to_gcp "$namespace"
    done

    cleanup

    echo ""
    log_success "All certificates generated!"
    echo ""
    echo "Certificates created for:"
    for namespace in "${NAMESPACES[@]}"; do
        local suffix=${namespace#postgresql-}
        echo "  - $namespace:"
        echo "      GCP: ${ENVIRONMENT}-postgresql-${suffix}-server-cert"
        echo "      GCP: ${ENVIRONMENT}-postgresql-${suffix}-server-key"
        echo "      GCP: ${ENVIRONMENT}-postgresql-${suffix}-ca-cert"
    done
    echo ""
    echo "Next: Run ./scripts/sync-postgresql-ssl.sh -e $ENVIRONMENT to sync to Kubernetes"
}

main
