#!/usr/bin/env bash
# =============================================================================
# SET REPO VARIABLES — Configure WIF_PROVIDER and CI_SERVICE_ACCOUNT for all repos
# =============================================================================
# GitHub Free plan: no org-level variables, so we set per-repo.
# Run once after WIF and service account are created by Terraform 03-iam.
# Requires: gh CLI authenticated with admin access to tesserix org.
# =============================================================================
set -euo pipefail

ORG="tesserix"

# Update these after Terraform creates the resources
WIF_PROVIDER="projects/1095627480948/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
CI_SERVICE_ACCOUNT="sa-github-ci@tesserix-app.iam.gserviceaccount.com"

REPOS=(
  auth-bff
  feature-flags-service
  status-service
  qr-service
  audit-service
  tenant-service
  notification-service
  settings-service
  subscription-service
  tickets-service
  document-service
  location-service
  verification-service
  analytics-service
  tenant-router-service
  tesserix-home
  marketplace-products-service
  marketplace-orders-service
  marketplace-payment-service
  marketplace-inventory-service
  marketplace-shipping-service
  marketplace-categories-service
  marketplace-coupons-service
  marketplace-reviews-service
  marketplace-vendor-service
  marketplace-customers-service
  marketplace-staff-service
  marketplace-content-service
  marketplace-approval-service
  marketplace-gift-cards-service
  marketplace-marketing-service
  marketplace-marketplace-connector-service
  marketplace-tax-service
  marketplace-onboarding
  marketplace-admin
  marketplace-storefront
  go-shared
)

echo "Setting repository variables for ${#REPOS[@]} repos..."
echo ""

for repo in "${REPOS[@]}"; do
  echo "Setting vars for ${ORG}/${repo}..."
  gh variable set WIF_PROVIDER --repo "${ORG}/${repo}" --body "${WIF_PROVIDER}" 2>/dev/null || \
    echo "  WARN: Failed to set WIF_PROVIDER for ${repo}"
  gh variable set CI_SERVICE_ACCOUNT --repo "${ORG}/${repo}" --body "${CI_SERVICE_ACCOUNT}" 2>/dev/null || \
    echo "  WARN: Failed to set CI_SERVICE_ACCOUNT for ${repo}"
  echo "  Done"
done

echo ""
echo "All repository variables set."
echo ""
echo "Also set these SECRETS per-repo (cannot be scripted without the values):"
echo "  - GO_PRIVATE_TOKEN: GitHub PAT with repo scope (for Go services)"
echo "  - PKG_READ_TOKEN: GitHub PAT or npm token (for Next.js services)"
echo "  - DISPATCH_TOKEN: GitHub PAT with repo scope (for go-shared only)"
