#!/bin/bash
# =============================================================================
# GCP Workload Identity Federation Setup for GitHub Actions
# =============================================================================
# This script sets up Workload Identity Federation (WIF) for GitHub Actions
# to authenticate with GCP without using service account keys.
#
# Usage: ./setup-gcp-wif.sh <environment>
#   environment: devtest | prod
#
# Prerequisites:
#   - gcloud CLI installed and authenticated with owner/admin permissions
#   - yq installed (for YAML parsing)
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load dependencies.yaml configuration
DEPS_FILE="${PROJECT_ROOT}/dependencies.yaml"

# =============================================================================
# Functions
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
    exit 1
}

usage() {
    echo "Usage: $0 <environment>"
    echo ""
    echo "Arguments:"
    echo "  environment    Target environment (devtest or prod)"
    echo ""
    echo "Examples:"
    echo "  $0 prod          # Setup WIF for production (tesseracthub-480811 project)"
    echo "  $0 devtest       # Setup WIF for devtest (tesseracthub project)"
    echo ""
    echo "This script will:"
    echo "  1. Enable required GCP APIs"
    echo "  2. Create Workload Identity Pool"
    echo "  3. Create Workload Identity Provider for GitHub"
    echo "  4. Create GitHub Actions service account"
    echo "  5. Bind service account to Workload Identity"
    echo "  6. Grant necessary IAM permissions"
    echo "  7. Output GitHub Secrets to configure"
    exit 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check gcloud
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI is not installed. Please install it first."
    fi

    # Check yq
    if ! command -v yq &> /dev/null; then
        log_error "yq is not installed. Please install it first: brew install yq"
    fi

    # Check gcloud authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1 > /dev/null 2>&1; then
        log_error "Not authenticated with gcloud. Run: gcloud auth login"
    fi

    # Check dependencies.yaml exists
    if [[ ! -f "$DEPS_FILE" ]]; then
        log_error "dependencies.yaml not found at: $DEPS_FILE"
    fi

    log_success "Prerequisites check passed"
}

load_config() {
    local env=$1

    log_info "Loading configuration for environment: $env"

    # Load project configuration from dependencies.yaml
    PROJECT_ID=$(yq e ".projects.${env}.id" "$DEPS_FILE")
    PROJECT_NUMBER=$(yq e ".projects.${env}.number" "$DEPS_FILE")
    PROJECT_NAME=$(yq e ".projects.${env}.name" "$DEPS_FILE")
    NAMING_PREFIX=$(yq e ".projects.${env}.naming_prefix" "$DEPS_FILE")

    if [[ "$PROJECT_ID" == "null" || -z "$PROJECT_ID" ]]; then
        log_error "Project configuration not found for environment: $env"
    fi

    # Set derived values
    POOL_ID="github-pool"
    PROVIDER_ID="github-provider"
    SA_NAME="github-actions"
    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    POOL_FULL_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
    PROVIDER_FULL_NAME="${POOL_FULL_NAME}/providers/${PROVIDER_ID}"

    log_success "Configuration loaded:"
    echo "  Project ID:     $PROJECT_ID"
    echo "  Project Number: $PROJECT_NUMBER"
    echo "  Project Name:   $PROJECT_NAME"
    echo "  Naming Prefix:  $NAMING_PREFIX"
    echo "  SA Email:       $SA_EMAIL"
}

enable_apis() {
    log_info "Enabling required GCP APIs..."

    local apis=(
        "iam.googleapis.com"
        "iamcredentials.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "sts.googleapis.com"
    )

    for api in "${apis[@]}"; do
        echo "  Enabling $api..."
        gcloud services enable "$api" --project="$PROJECT_ID" --quiet
    done

    log_success "APIs enabled"
}

create_workload_identity_pool() {
    log_info "Creating Workload Identity Pool..."

    # Check if pool already exists
    if gcloud iam workload-identity-pools describe "$POOL_ID" \
        --project="$PROJECT_ID" \
        --location="global" &> /dev/null; then
        log_warning "Workload Identity Pool '$POOL_ID' already exists. Skipping creation."
        return
    fi

    gcloud iam workload-identity-pools create "$POOL_ID" \
        --project="$PROJECT_ID" \
        --location="global" \
        --display-name="GitHub Actions Pool" \
        --description="Workload Identity Pool for GitHub Actions CI/CD"

    log_success "Workload Identity Pool created"
}

create_workload_identity_provider() {
    log_info "Creating Workload Identity Provider..."

    # Check if provider already exists
    if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" &> /dev/null; then
        log_warning "Workload Identity Provider '$PROVIDER_ID' already exists. Skipping creation."
        return
    fi

    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" \
        --display-name="GitHub Provider" \
        --description="OIDC provider for GitHub Actions" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
        --attribute-condition="assertion.repository_owner == 'tesserix'"

    log_success "Workload Identity Provider created"
}

create_service_account() {
    log_info "Creating GitHub Actions service account..."

    # Check if SA already exists
    if gcloud iam service-accounts describe "$SA_EMAIL" \
        --project="$PROJECT_ID" &> /dev/null; then
        log_warning "Service account '$SA_EMAIL' already exists. Skipping creation."
        return
    fi

    gcloud iam service-accounts create "$SA_NAME" \
        --project="$PROJECT_ID" \
        --display-name="GitHub Actions Service Account" \
        --description="Service account for GitHub Actions CI/CD workflows"

    log_success "Service account created: $SA_EMAIL"
}

bind_service_account_to_wif() {
    log_info "Binding service account to Workload Identity..."

    # Allow the WIF pool to impersonate the service account
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --role="roles/iam.workloadIdentityUser" \
        --member="principalSet://iam.googleapis.com/${POOL_FULL_NAME}/attribute.repository_owner/tesserix"

    log_success "Workload Identity binding created"
}

grant_iam_permissions() {
    log_info "Granting IAM permissions to service account..."

    # Permissions needed for Terraform deployments
    local roles=(
        "roles/compute.admin"
        "roles/container.admin"
        "roles/iam.serviceAccountAdmin"
        "roles/iam.serviceAccountUser"
        "roles/iam.workloadIdentityPoolAdmin"
        "roles/secretmanager.admin"
        "roles/storage.admin"
        "roles/cloudkms.admin"
        "roles/pubsub.admin"
        "roles/dns.admin"
        "roles/servicenetworking.networksAdmin"
        "roles/resourcemanager.projectIamAdmin"
        "roles/serviceusage.serviceUsageAdmin"
    )

    for role in "${roles[@]}"; do
        echo "  Granting $role..."
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --role="$role" \
            --member="serviceAccount:${SA_EMAIL}" \
            --condition=None \
            --quiet
    done

    log_success "IAM permissions granted"
}

print_github_secrets() {
    log_info "GitHub Secrets to configure:"
    echo ""
    echo "============================================================================="
    echo "Add the following secrets to your GitHub repository:"
    echo "============================================================================="
    echo ""
    echo "Go to: https://github.com/<org>/<repo>/settings/secrets/actions"
    echo ""
    echo "Required Secrets:"
    echo "-----------------"
    echo ""

    if [[ "$ENV" == "prod" ]]; then
        echo "GCP_PROD_PROJECT_ID = $PROJECT_ID"
        echo ""
        echo "GCP_PROD_WIF_PROVIDER = $PROVIDER_FULL_NAME"
        echo ""
        echo "GCP_PROD_WIF_SA_EMAIL = $SA_EMAIL"
    else
        echo "GCP_DEVTEST_PROJECT_ID = $PROJECT_ID"
        echo ""
        echo "GCP_DEVTEST_WIF_PROVIDER = $PROVIDER_FULL_NAME"
        echo ""
        echo "GCP_DEVTEST_WIF_SA_EMAIL = $SA_EMAIL"
    fi

    echo ""
    echo "============================================================================="
    echo "Example GitHub Actions Workflow Configuration:"
    echo "============================================================================="
    echo ""
    cat << 'EOF'
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # Required for WIF

    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_PROD_WIF_PROVIDER }}
          service_account: ${{ secrets.GCP_PROD_WIF_SA_EMAIL }}
          project_id: ${{ secrets.GCP_PROD_PROJECT_ID }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.0

      - name: Terraform Init
        run: terraform init
        working-directory: terraform-new/stacks/01-foundation
EOF
    echo ""
    echo "============================================================================="
}

print_verification_commands() {
    log_info "Verification commands:"
    echo ""
    echo "# Verify Workload Identity Pool"
    echo "gcloud iam workload-identity-pools describe $POOL_ID \\"
    echo "  --project=$PROJECT_ID \\"
    echo "  --location=global"
    echo ""
    echo "# Verify Workload Identity Provider"
    echo "gcloud iam workload-identity-pools providers describe $PROVIDER_ID \\"
    echo "  --project=$PROJECT_ID \\"
    echo "  --location=global \\"
    echo "  --workload-identity-pool=$POOL_ID"
    echo ""
    echo "# Verify Service Account"
    echo "gcloud iam service-accounts describe $SA_EMAIL \\"
    echo "  --project=$PROJECT_ID"
    echo ""
    echo "# List Service Account IAM bindings"
    echo "gcloud iam service-accounts get-iam-policy $SA_EMAIL \\"
    echo "  --project=$PROJECT_ID"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    ENV=$1

    if [[ "$ENV" != "devtest" && "$ENV" != "prod" ]]; then
        log_error "Invalid environment: $ENV. Must be 'devtest' or 'prod'"
    fi

    echo ""
    echo "============================================================================="
    echo "GCP Workload Identity Federation Setup"
    echo "============================================================================="
    echo "Environment: $ENV"
    echo "============================================================================="
    echo ""

    check_prerequisites
    load_config "$ENV"

    echo ""
    read -p "Do you want to proceed with the setup? (y/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Setup cancelled by user"
        exit 0
    fi

    echo ""
    enable_apis
    create_workload_identity_pool
    create_workload_identity_provider
    create_service_account
    bind_service_account_to_wif
    grant_iam_permissions

    echo ""
    print_github_secrets
    print_verification_commands

    log_success "Setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Add the GitHub Secrets shown above to your repository"
    echo "  2. Update the attribute-condition in the WIF provider if needed"
    echo "  3. Test the workflow authentication"
    echo ""
}

main "$@"
