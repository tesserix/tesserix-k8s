#!/usr/bin/env bash
# =============================================================================
# UPDATE SERVICE WORKFLOWS — Inline CI/CD for GitHub Free plan
# =============================================================================
# Generates ci.yml and release.yml for all service repos.
# All steps are inlined (no cross-repo reusable workflows) because
# GitHub Free does not support calling reusable workflows from private repos.
# =============================================================================
set -euo pipefail

REPOS_DIR="${1:-/Users/Mahesh.Sangawar/personal/tesserix-new}"

# ---------------------------------------------------------------------------
# SERVICE DEFINITIONS
# Format: repo_dir|service_name|lang|migration|db_name|db_user|db_secret_name
# ---------------------------------------------------------------------------
SERVICES=(
  # PLATFORM — Go services (no DB)
  "auth-bff|auth-bff|go|none|||"
  "feature-flags-service|feature-flags-service|go|none|||"
  "status-service|status-service|go|none|||"
  "qr-service|qr-service|go|none|||"

  # PLATFORM — Go services (with DB + golang-migrate)
  "audit-service|audit-service|go|golang-migrate|audit_db|audit_user|audit-db-password"
  "tenant-service|tenant-service|go|golang-migrate|tenant_db|tenant_user|tenant-db-password"
  "notification-service|notification-service|go|golang-migrate|notification_db|notification_user|notification-db-password"
  "settings-service|settings-service|go|golang-migrate|settings_db|settings_user|settings-db-password"
  "subscription-service|subscription-service|go|golang-migrate|subscription_db|subscription_user|subscription-db-password"
  "tickets-service|tickets-service|go|golang-migrate|tickets_db|tickets_user|tickets-db-password"
  "document-service|document-service|go|golang-migrate|document_db|document_user|document-db-password"
  "location-service|location-service|go|golang-migrate|location_db|location_user|location-db-password"
  "verification-service|verification-service|go|golang-migrate|verification_db|verification_user|verification-db-password"
  "analytics-service|analytics-service|go|none|||"
  "tenant-router-service|tenant-router-service|go|golang-migrate|tenant_router_db|tenant_router_user|tenant-router-db-password"

  # PLATFORM — Next.js services
  "tesserix-home|tesserix-home|nextjs|none|||"

  # MARKETPLACE — Go services (all with DB + golang-migrate)
  "marketplace-products-service|mp-products|go|golang-migrate|mp_products_db|mp_products_user|mp_products-db-password"
  "marketplace-orders-service|mp-orders|go|golang-migrate|mp_orders_db|mp_orders_user|mp_orders-db-password"
  "marketplace-payment-service|mp-payments|go|golang-migrate|mp_payments_db|mp_payments_user|mp_payments-db-password"
  "marketplace-inventory-service|mp-inventory|go|golang-migrate|mp_inventory_db|mp_inventory_user|mp_inventory-db-password"
  "marketplace-shipping-service|mp-shipping|go|golang-migrate|mp_shipping_db|mp_shipping_user|mp_shipping-db-password"
  "marketplace-categories-service|mp-categories|go|golang-migrate|mp_categories_db|mp_categories_user|mp_categories-db-password"
  "marketplace-coupons-service|mp-coupons|go|golang-migrate|mp_coupons_db|mp_coupons_user|mp_coupons-db-password"
  "marketplace-reviews-service|mp-reviews|go|golang-migrate|mp_reviews_db|mp_reviews_user|mp_reviews-db-password"
  "marketplace-vendor-service|mp-vendors|go|golang-migrate|mp_vendors_db|mp_vendors_user|mp_vendors-db-password"
  "marketplace-customers-service|mp-customers|go|golang-migrate|mp_customers_db|mp_customers_user|mp_customers-db-password"
  "marketplace-staff-service|mp-staff|go|golang-migrate|mp_staff_db|mp_staff_user|mp_staff-db-password"
  "marketplace-content-service|mp-content|go|golang-migrate|mp_content_db|mp_content_user|mp_content-db-password"
  "marketplace-approval-service|mp-approvals|go|golang-migrate|mp_approvals_db|mp_approvals_user|mp_approvals-db-password"
  "marketplace-gift-cards-service|mp-gift-cards|go|golang-migrate|mp_gift_cards_db|mp_gift_cards_user|mp_gift_cards-db-password"
  "marketplace-marketing-service|mp-marketing|go|golang-migrate|mp_marketing_db|mp_marketing_user|mp_marketing-db-password"
  "marketplace-marketplace-connector-service|mp-connector|go|golang-migrate|mp_connector_db|mp_connector_user|mp_connector-db-password"
  "marketplace-tax-service|mp-tax|go|golang-migrate|mp_tax_db|mp_tax_user|mp_tax-db-password"

  # MARKETPLACE — Next.js services
  "marketplace-onboarding|marketplace-onboarding|nextjs|drizzle|mp_onboarding_db|mp_onboarding_user|mp_onboarding-db-password"
  "marketplace-admin|marketplace-admin|nextjs|none|||"
  "marketplace-storefront|mp-storefront|nextjs|none|||"
)

# ---------------------------------------------------------------------------
# GENERATORS — all steps inlined (GitHub Free compatible)
# ---------------------------------------------------------------------------

generate_go_ci() {
  local service_name="$1"
  local migration="$2"
  local db_name="$3"
  local db_user="$4"
  local db_secret="$5"
  local has_migrations_dir="$6"

  local paths_block=""
  if [[ "$has_migrations_dir" == "true" || "$migration" == "golang-migrate" ]]; then
    paths_block="      - 'migrations/**'"
  fi

  local migrate_job=""
  if [[ "$migration" == "golang-migrate" ]]; then
    migrate_job="
  migrate:
    needs: [build-and-push]
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: \${{ vars.WIF_PROVIDER }}
          service_account: \${{ vars.CI_SERVICE_ACCOUNT }}

      - name: Set up Cloud SDK
        uses: google-github-actions/setup-gcloud@v2

      - name: Install Cloud SQL Auth Proxy
        run: |
          curl -sSL https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.3/cloud-sql-proxy.linux.amd64 \\
            -o cloud-sql-proxy
          chmod +x cloud-sql-proxy

      - name: Install golang-migrate
        run: |
          curl -sSL https://github.com/golang-migrate/migrate/releases/download/v4.18.1/migrate.linux-amd64.tar.gz \\
            | tar xz
          chmod +x migrate

      - name: Fetch DB password from Secret Manager
        id: db_password
        run: |
          PASSWORD=\$(gcloud secrets versions access latest \\
            --secret=\"${db_secret}\" \\
            --project=\"tesserix\")
          echo \"::add-mask::\${PASSWORD}\"
          echo \"password=\${PASSWORD}\" >> \"\$GITHUB_OUTPUT\"

      - name: Start Cloud SQL Auth Proxy
        run: |
          ./cloud-sql-proxy \"tesserix:asia-south1:tesserix-main\" \\
            --port 5432 \\
            --quiet &
          for i in \$(seq 1 10); do
            if nc -z 127.0.0.1 5432 2>/dev/null; then
              echo \"Cloud SQL proxy is ready\"
              break
            fi
            if [ \"\$i\" = \"10\" ]; then
              echo \"::error::Cloud SQL proxy failed to start\"
              exit 1
            fi
            sleep 1
          done

      - name: Run migrations
        env:
          DATABASE_URL: \"postgres://${db_user}:\${{ steps.db_password.outputs.password }}@127.0.0.1:5432/${db_name}?sslmode=disable\"
        run: |
          echo \"Running migrations for ${service_name} on ${db_name}...\"
          ./migrate \\
            -path \"migrations\" \\
            -database \"\$DATABASE_URL\" \\
            up
          echo \"Migrations completed successfully\"

      - name: Show migration version
        if: always()
        env:
          DATABASE_URL: \"postgres://${db_user}:\${{ steps.db_password.outputs.password }}@127.0.0.1:5432/${db_name}?sslmode=disable\"
        run: |
          ./migrate \\
            -path \"migrations\" \\
            -database \"\$DATABASE_URL\" \\
            version 2>&1 || true"
  fi

  cat <<EOF
name: CI

on:
  push:
    branches: [main, 'feat/**', 'feature/**', 'bugfix/**', 'hotfix/**']
    paths:
      - '**/*.go'
      - 'go.mod'
      - 'go.sum'
      - 'Dockerfile'
${paths_block:+${paths_block}
}      - '.github/workflows/ci.yml'
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-\${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${service_name}

permissions:
  contents: read
  security-events: write
  id-token: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.26'

      - name: Run tests
        env:
          GOPRIVATE: github.com/tesserix/*
        run: |
          go vet ./...
          go test -race -coverprofile=coverage.out ./...

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: \${{ vars.WIF_PROVIDER }}
          service_account: \${{ vars.CI_SERVICE_ACCOUNT }}

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: \${{ env.REGISTRY }}
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        run: |
          if [[ "\${{ github.ref }}" == refs/tags/v* ]]; then
            echo "tag=\${GITHUB_REF#refs/tags/}" >> \$GITHUB_OUTPUT
          else
            echo "tag=main-\${GITHUB_SHA::7}" >> \$GITHUB_OUTPUT
          fi

      - name: Build and push
        run: |
          docker build \\
            --secret id=github_token,env=GITHUB_TOKEN \\
            --platform linux/amd64 \\
            -t \${{ env.REGISTRY }}/\${{ github.repository_owner }}/\${{ env.IMAGE_NAME }}:\${{ steps.meta.outputs.tag }} \\
            -t \${{ env.REGISTRY }}/\${{ github.repository_owner }}/\${{ env.IMAGE_NAME }}:latest \\
            .
          docker push --all-tags \${{ env.REGISTRY }}/\${{ github.repository_owner }}/\${{ env.IMAGE_NAME }}
        env:
          GITHUB_TOKEN: \${{ secrets.GO_PRIVATE_TOKEN }}

      - name: Security scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: \${{ env.REGISTRY }}/\${{ github.repository_owner }}/\${{ env.IMAGE_NAME }}:\${{ steps.meta.outputs.tag }}
          format: sarif
          output: trivy-results.sarif
          severity: CRITICAL,HIGH
          exit-code: "0"

      - name: Upload scan results
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif
