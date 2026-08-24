# Identity Platform Stack — Multi-Tenant Configuration
# State: stacks/prod/identity-platform/default.tfstate
# Dependencies: 01-foundation
#
# Per-product GIP tenants provide user pool isolation between products.
# Each product gets an "internal" tenant (staff/admins) and a "customer" tenant
# (end-users). GIP tenants are free — cost is per MAU, not per tenant.
#
# OAuth clients are created in GCP Console (Credentials page), not here.
# Authorized domains are project-level and cover all tenants.

# Reference foundation stack outputs
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/foundation"
  }
}

# =============================================================================
# Identity Platform Project-Level Config
# =============================================================================

resource "google_identity_platform_config" "default" {
  count   = var.enable_identity_platform ? 1 : 0
  project = var.project_id

  # Authorized domains apply to ALL tenants in the project.
  # Wildcard subdomains are not supported here — GIP auto-allows
  # subdomains of listed domains for OAuth redirects.
  #
  # NOTE: Custom tenant domains (e.g., shop.example.com) are NOT subdomains
  # of mark8ly.com. Currently safe because:
  # - Admin auth uses {slug}-admin.mark8ly.com (covered by mark8ly.com)
  # - Customer auth uses {slug}.mark8ly.com (covered by mark8ly.com)
  # - Custom domains serve storefront content only, no GIP OAuth redirects
  # If custom domains ever need GIP OAuth (e.g., social login on custom domain),
  # add dynamic authorized_domain registration in tenant-router-service.
  authorized_domains = var.authorized_domains

  multi_tenant {
    allow_tenants = true
  }

  sign_in {
    allow_duplicate_emails = var.allow_duplicate_emails

    email {
      enabled           = true
      password_required = true
    }
  }

  depends_on = [data.terraform_remote_state.foundation]
}

# =============================================================================
# Identity Platform Tenants
# =============================================================================

resource "google_identity_platform_tenant" "tenants" {
  for_each = {
    for tenant in var.identity_platform_tenants : tenant.name => tenant
  }

  project      = var.project_id
  display_name = each.value.display_name

  allow_password_signup = each.value.allow_password_signup

  depends_on = [google_identity_platform_config.default]
}
