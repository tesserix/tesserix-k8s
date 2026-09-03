# Workload Identity Stack - Service Accounts and WI Bindings
# State: stacks/prod/workload-identity/default.tfstate
# Dependencies: 04-gke, 03-storage

# Reference other stacks
data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/gke"
  }
}

data "terraform_remote_state" "storage" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/storage"
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

import {
  to = google_service_account.workload_identity["evals-onboarding-operator"]
  id = "projects/tesseracthub-480811/serviceAccounts/evals-onboarding-operator@tesseracthub-480811.iam.gserviceaccount.com"
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
# Secret Provisioner
# =============================================================================
# These live in state but had no configuration, so any apply planned to DELETE
# a live production service account. Re-declared from the recorded state; the
# former project-level tokenCreator is now a self-binding.

resource "google_service_account" "secret_provisioner" {
  account_id   = "secret-provisioner-sa"
  display_name = "Secret Provisioner Service"
  description  = "Service account for the secret-provisioner global service to manage payment credentials in GCP Secret Manager"
}

resource "google_project_iam_member" "secret_provisioner_secretmanager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = google_service_account.secret_provisioner.member
}

resource "google_service_account_iam_member" "secret_provisioner_token_creator" {
  service_account_id = google_service_account.secret_provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.secret_provisioner.member
}

resource "google_service_account_iam_member" "secret_provisioner_workload_identity_global" {
  service_account_id = google_service_account.secret_provisioner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[global/secret-provisioner]"
}

resource "google_service_account_iam_member" "secret_provisioner_workload_identity_global_services" {
  service_account_id = google_service_account.secret_provisioner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[global-services/secret-provisioner]"
}

# =============================================================================
# Write-blind Secret Manager role
# =============================================================================
# The secret-service console creates, versions, disables and destroys secrets
# but must never read one back. roles/secretmanager.admin includes
# versions.access, so the console gets this role instead: everything except the
# payload. Referenced from tfvars as projects/<project>/roles/<role_id>.

resource "google_project_iam_custom_role" "secret_manager_write_blind" {
  role_id     = "secretManagerWriteBlind"
  title       = "Secret Manager Write-Blind"
  description = "Manage secrets and versions without permission to read a payload"
  project     = var.project_id
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.update",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.disable",
    "secretmanager.versions.enable",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
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
