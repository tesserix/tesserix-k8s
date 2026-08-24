# App Secrets Stack - Application Secrets in Secret Manager
# State: stacks/prod/app-secrets/default.tfstate
# Dependencies: 04-gke, 06-workload-identity

# Reference other stacks
data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/gke"
  }
}

data "terraform_remote_state" "workload_identity" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/workload-identity"
  }
}

# =============================================================================
# Application Secrets
# =============================================================================

resource "google_secret_manager_secret" "app_secrets" {
  for_each = { for secret in var.app_secrets : secret.name => secret }

  secret_id = each.value.name
  project   = var.project_id

  labels = merge(var.common_labels, {
    category    = each.value.category
    environment = var.environment
  })

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "app_secrets" {
  for_each = {
    for secret in var.app_secrets : secret.name => secret
    if secret.value != null && secret.value != ""
  }

  secret      = google_secret_manager_secret.app_secrets[each.key].id
  secret_data = each.value.value

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# =============================================================================
# Namespace Service Accounts for Secret Access
# =============================================================================

resource "google_service_account" "namespace_secret_accessor" {
  for_each = toset(var.namespaces)

  account_id   = "${var.environment}-${each.value}-secrets"
  display_name = "${each.value} namespace secrets accessor"
  description  = "Service account for ${each.value} namespace to access secrets"
  project      = var.project_id
}

# Grant secret accessor role to namespace service accounts
resource "google_secret_manager_secret_iam_member" "namespace_access" {
  for_each = {
    for binding in local.namespace_secret_bindings :
    "${binding.namespace}-${binding.secret_name}" => binding
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.app_secrets[each.value.secret_name].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.namespace_secret_accessor[each.value.namespace].email}"
}

# Workload Identity binding for namespace service accounts
resource "google_service_account_iam_member" "namespace_workload_identity" {
  for_each = toset(var.namespaces)

  service_account_id = google_service_account.namespace_secret_accessor[each.value].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value}/default]"
}

# =============================================================================
# Locals
# =============================================================================

locals {
  namespace_secret_bindings = flatten([
    for namespace in var.namespaces : [
      for secret in var.app_secrets : {
        namespace   = namespace
        secret_name = secret.name
      }
      if contains(secret.accessible_namespaces, namespace) || contains(secret.accessible_namespaces, "*")
    ]
  ])
}
