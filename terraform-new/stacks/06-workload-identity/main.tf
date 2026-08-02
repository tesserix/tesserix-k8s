# Workload Identity Stack - Service Accounts and WI Bindings
# State: stacks/{environment}/workload-identity/default.tfstate
# Dependencies: 04-gke, 03-storage

# Reference other stacks
data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/${var.environment}/gke"
  }
}

data "terraform_remote_state" "storage" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/${var.environment}/storage"
  }
}

# =============================================================================
# Service Accounts
# =============================================================================

resource "google_service_account" "workload_identity" {
  for_each = { for sa in var.service_accounts : sa.name => sa }

  account_id   = each.value.name
  display_name = each.value.display_name
  description  = each.value.description
  project      = var.project_id
}

# =============================================================================
# Workload Identity Bindings (GSA to KSA)
# =============================================================================

resource "google_service_account_iam_member" "workload_identity_binding" {
  for_each = {
    for binding in local.workload_identity_bindings :
    "${binding.sa_name}-${binding.namespace}-${binding.ksa_name}" => binding
  }

  service_account_id = google_service_account.workload_identity[each.value.sa_name].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.namespace}/${each.value.ksa_name}]"
}

# =============================================================================
# Self-impersonation (signing) — scoped to the SA itself
# =============================================================================

resource "google_service_account_iam_member" "self_token_creator" {
  for_each = {
    for sa in var.service_accounts : sa.name => sa
    if sa.self_token_creator
  }

  service_account_id = google_service_account.workload_identity[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.workload_identity[each.key].email}"
}

# =============================================================================
# Project-level IAM Roles
# =============================================================================

resource "google_project_iam_member" "project_roles" {
  for_each = {
    for binding in local.project_role_bindings :
    "${binding.sa_name}-${binding.role}" => binding
  }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload_identity[each.value.sa_name].email}"
}

# =============================================================================
# Bucket IAM Bindings
# =============================================================================

resource "google_storage_bucket_iam_member" "bucket_access" {
  for_each = {
    for binding in local.bucket_bindings :
    "${binding.sa_name}-${binding.bucket}-${binding.role}" => binding
  }

  bucket = each.value.bucket
  role   = each.value.role
  member = "serviceAccount:${google_service_account.workload_identity[each.value.sa_name].email}"
}

# =============================================================================
# Secret Manager IAM Bindings
# =============================================================================

resource "google_secret_manager_secret_iam_member" "secret_access" {
  for_each = {
    for binding in local.secret_bindings :
    "${binding.sa_name}-${binding.secret_id}-${binding.role}" => binding
  }

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = each.value.role
  member    = "serviceAccount:${google_service_account.workload_identity[each.value.sa_name].email}"
}

# =============================================================================
# Locals
# =============================================================================

locals {
  workload_identity_bindings = flatten([
    for sa in var.service_accounts : [
      for wi in sa.workload_identity_bindings : {
        sa_name   = sa.name
        namespace = wi.namespace
        ksa_name  = wi.kubernetes_service_account
      }
    ]
  ])

  project_role_bindings = flatten([
    for sa in var.service_accounts : [
      for role in sa.project_roles : {
        sa_name = sa.name
        role    = role
      }
    ]
  ])

  bucket_bindings = flatten([
    for sa in var.service_accounts : [
      for binding in sa.bucket_bindings : {
        sa_name = sa.name
        bucket  = binding.bucket
        role    = binding.role
      }
    ]
  ])

  secret_bindings = flatten([
    for sa in var.service_accounts : [
      for binding in sa.secret_bindings : {
        sa_name   = sa.name
        secret_id = binding.secret_id
        role      = binding.role
      }
    ]
  ])
}
