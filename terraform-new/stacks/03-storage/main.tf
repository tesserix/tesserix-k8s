# Storage Stack - GCS Buckets, Secret Manager, KMS
# State: stacks/prod/storage/default.tfstate
# Dependencies: 01-foundation

# Reference foundation stack outputs
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/foundation"
  }
}

# Get project details for service agent email
data "google_project" "project" {
  project_id = var.project_id
}

# =============================================================================
# KMS Keyring
# =============================================================================

resource "google_kms_key_ring" "keyring" {
  count    = var.create_kms_keyring ? 1 : 0
  name     = var.kms_keyring_name
  project  = var.project_id
  location = var.kms_location

  depends_on = [data.terraform_remote_state.foundation]
}

# =============================================================================
# KMS Crypto Keys
# =============================================================================

resource "google_kms_crypto_key" "keys" {
  for_each = { for key in var.kms_keys : key.name => key }

  name            = each.value.name
  key_ring        = var.create_kms_keyring ? google_kms_key_ring.keyring[0].id : each.value.key_ring_id
  rotation_period = each.value.rotation_period
  purpose         = each.value.purpose

  version_template {
    algorithm        = each.value.algorithm
    protection_level = each.value.protection_level
  }

  labels = merge(var.common_labels, each.value.labels)

  destroy_scheduled_duration = each.value.destroy_scheduled_duration
  import_only                = each.value.import_only

  lifecycle {
    prevent_destroy = false
  }
}

# KMS Crypto Key IAM bindings
resource "google_kms_crypto_key_iam_member" "key_members" {
  for_each = {
    for binding in local.key_iam_bindings : "${binding.key_name}-${binding.role}-${binding.member}" => binding
  }

  crypto_key_id = google_kms_crypto_key.keys[each.value.key_name].id
  role          = each.value.role
  member        = each.value.member
}

# =============================================================================
# GCS Buckets
# =============================================================================

resource "google_storage_bucket" "buckets" {
  for_each = { for bucket in var.buckets : bucket.name => bucket }

  name          = each.value.name
  project       = var.project_id
  location      = each.value.location != null ? each.value.location : var.default_bucket_location
  storage_class = each.value.storage_class
  force_destroy = each.value.force_destroy

  uniform_bucket_level_access = each.value.uniform_bucket_level_access
  public_access_prevention    = each.value.public_access_prevention

  dynamic "versioning" {
    for_each = each.value.versioning ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "lifecycle_rule" {
    for_each = each.value.lifecycle_rules
    content {
      action {
        type          = lifecycle_rule.value.action.type
        storage_class = lifecycle_rule.value.action.storage_class
      }
      condition {
        age                        = lifecycle_rule.value.condition.age
        created_before             = lifecycle_rule.value.condition.created_before
        with_state                 = lifecycle_rule.value.condition.with_state
        matches_storage_class      = lifecycle_rule.value.condition.matches_storage_class
        matches_prefix             = lifecycle_rule.value.condition.matches_prefix
        matches_suffix             = lifecycle_rule.value.condition.matches_suffix
        num_newer_versions         = lifecycle_rule.value.condition.num_newer_versions
        days_since_noncurrent_time = lifecycle_rule.value.condition.days_since_noncurrent_time
      }
    }
  }

  dynamic "encryption" {
    for_each = each.value.kms_key_name != null ? [1] : []
    content {
      default_kms_key_name = each.value.kms_key_name
    }
  }

  dynamic "cors" {
    for_each = each.value.cors
    content {
      origin          = cors.value.origin
      method          = cors.value.method
      response_header = cors.value.response_header
      max_age_seconds = cors.value.max_age_seconds
    }
  }

  labels = merge(var.common_labels, each.value.labels)

  depends_on = [data.terraform_remote_state.foundation]
}

# Bucket IAM bindings
resource "google_storage_bucket_iam_member" "members" {
  for_each = {
    for binding in local.bucket_iam_bindings : "${binding.bucket}-${binding.role}-${binding.member}" => binding
  }

  bucket = google_storage_bucket.buckets[each.value.bucket].name
  role   = each.value.role
  member = each.value.member
}

# =============================================================================
# Secret Manager - Secrets
# =============================================================================

resource "google_secret_manager_secret" "secrets" {
  for_each = { for secret in var.secrets : secret.secret_id => secret }

  secret_id   = each.value.secret_id
  project     = var.project_id
  labels      = merge(var.common_labels, each.value.labels)
  annotations = each.value.annotations
  expire_time = each.value.expire_time
  ttl         = each.value.ttl

  version_aliases = each.value.version_aliases

  replication {
    dynamic "user_managed" {
      for_each = each.value.replication_locations != null ? [1] : []
      content {
        dynamic "replicas" {
          for_each = each.value.replication_locations
          content {
            location = replicas.value.location

            dynamic "customer_managed_encryption" {
              for_each = replicas.value.kms_key_name != null ? [1] : []
              content {
                kms_key_name = replicas.value.kms_key_name
              }
            }
          }
        }
      }
    }

    dynamic "auto" {
      for_each = each.value.replication_locations == null ? [1] : []
      content {
        dynamic "customer_managed_encryption" {
          for_each = each.value.auto_cmek_key_name != null ? [1] : []
          content {
            kms_key_name = each.value.auto_cmek_key_name
          }
        }
      }
    }
  }

  dynamic "topics" {
    for_each = each.value.pubsub_topics != null ? each.value.pubsub_topics : []
    content {
      name = topics.value
    }
  }

  dynamic "rotation" {
    for_each = each.value.rotation_period != null ? [1] : []
    content {
      rotation_period    = each.value.rotation_period
      next_rotation_time = each.value.next_rotation_time
    }
  }

  depends_on = [google_kms_crypto_key.keys]
}

# Secret versions
resource "google_secret_manager_secret_version" "versions" {
  for_each = {
    for secret in var.secrets : secret.secret_id => secret
    if secret.secret_data != null
  }

  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value.secret_data
  enabled     = each.value.version_enabled

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Secret IAM bindings
resource "google_secret_manager_secret_iam_member" "members" {
  for_each = {
    for binding in local.secret_iam_bindings : "${binding.secret_id}-${binding.role}-${binding.member}" => binding
  }

  secret_id = google_secret_manager_secret.secrets[each.value.secret_id].secret_id
  project   = var.project_id
  role      = each.value.role
  member    = each.value.member
}

# Create Secret Manager service identity (service agent)
# This must exist before we can grant it KMS permissions
resource "google_project_service_identity" "secret_manager" {
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"
}

# Wait for service account to propagate globally in GCP
# This prevents race conditions when granting IAM permissions
resource "time_sleep" "wait_for_service_agent" {
  depends_on      = [google_project_service_identity.secret_manager]
  create_duration = "30s"
}

# Grant KMS permissions to Secret Manager service agent for CMEK
resource "google_kms_crypto_key_iam_member" "secret_manager_service_agent" {
  for_each = var.enable_cmek && var.create_kms_keyring ? {
    for key in var.kms_keys : key.name => key
    if key.purpose == "ENCRYPT_DECRYPT"
  } : {}

  crypto_key_id = google_kms_crypto_key.keys[each.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secret_manager.email}"

  depends_on = [time_sleep.wait_for_service_agent]
}

# =============================================================================
# Artifact Registry — Docker Repositories (Standard, where we push our own images)
# =============================================================================

resource "google_artifact_registry_repository" "docker" {
  for_each = { for repo in var.docker_repositories : repo.name => repo }

  repository_id = each.value.name
  project       = var.project_id
  location      = each.value.location != null ? each.value.location : var.region
  format        = "DOCKER"
  description   = each.value.description
  mode          = "STANDARD_REPOSITORY"

  labels = merge(var.common_labels, each.value.labels)

  cleanup_policy_dry_run = false

  dynamic "cleanup_policies" {
    for_each = each.value.cleanup_policies
    content {
      id     = cleanup_policies.value.id
      action = cleanup_policies.value.action
      dynamic "condition" {
        for_each = cleanup_policies.value.condition != null ? [cleanup_policies.value.condition] : []
        content {
          tag_state             = condition.value.tag_state
          tag_prefixes          = condition.value.tag_prefixes
          version_name_prefixes = condition.value.version_name_prefixes
          package_name_prefixes = condition.value.package_name_prefixes
          older_than            = condition.value.older_than
          newer_than            = condition.value.newer_than
        }
      }
      dynamic "most_recent_versions" {
        for_each = cleanup_policies.value.most_recent_versions != null ? [cleanup_policies.value.most_recent_versions] : []
        content {
          package_name_prefixes = most_recent_versions.value.package_name_prefixes
          keep_count            = most_recent_versions.value.keep_count
        }
      }
    }
  }

  depends_on = [data.terraform_remote_state.foundation]
}

# =============================================================================
# Artifact Registry — Docker Remote (Pull-Through Cache) Repositories
# Cleanup policies prune cached images so the cache stays small and cheap.
# =============================================================================

resource "google_artifact_registry_repository" "docker_remote" {
  for_each = { for repo in var.remote_docker_repositories : repo.name => repo }

  provider = google-beta

  repository_id = each.value.name
  project       = var.project_id
  location      = each.value.location != null ? each.value.location : var.region
  format        = "DOCKER"
  description   = each.value.description
  mode          = "REMOTE_REPOSITORY"

  labels = merge(var.common_labels, each.value.labels)

  cleanup_policy_dry_run = each.value.cleanup_policy_dry_run

  remote_repository_config {
    description                 = each.value.remote_description
    disable_upstream_validation = each.value.disable_upstream_validation

    docker_repository {
      public_repository = each.value.public_repository

      dynamic "custom_repository" {
        for_each = each.value.common_repository_uri != null ? [1] : []
        content {
          uri = each.value.common_repository_uri
        }
      }
    }

    dynamic "upstream_credentials" {
      for_each = each.value.upstream_credentials != null ? [each.value.upstream_credentials] : []
      content {
        username_password_credentials {
          username                = upstream_credentials.value.username
          password_secret_version = upstream_credentials.value.password_secret_version
        }
      }
    }
  }

  dynamic "cleanup_policies" {
    for_each = each.value.cleanup_policies
    content {
      id     = cleanup_policies.value.id
      action = cleanup_policies.value.action
      dynamic "condition" {
        for_each = cleanup_policies.value.condition != null ? [cleanup_policies.value.condition] : []
        content {
          tag_state             = condition.value.tag_state
          tag_prefixes          = condition.value.tag_prefixes
          version_name_prefixes = condition.value.version_name_prefixes
          package_name_prefixes = condition.value.package_name_prefixes
          older_than            = condition.value.older_than
          newer_than            = condition.value.newer_than
        }
      }
      dynamic "most_recent_versions" {
        for_each = cleanup_policies.value.most_recent_versions != null ? [cleanup_policies.value.most_recent_versions] : []
        content {
          package_name_prefixes = most_recent_versions.value.package_name_prefixes
          keep_count            = most_recent_versions.value.keep_count
        }
      }
    }
  }

  depends_on = [data.terraform_remote_state.foundation]
}

# =============================================================================
# Locals
# =============================================================================

locals {
  bucket_iam_bindings = flatten([
    for bucket in var.buckets : [
      for binding in bucket.iam_bindings : {
        bucket = bucket.name
        role   = binding.role
        member = binding.member
      }
    ]
  ])

  secret_iam_bindings = flatten([
    for secret in var.secrets : [
      for binding in secret.iam_bindings : {
        secret_id = secret.secret_id
        role      = binding.role
        member    = binding.member
      }
    ]
  ])

  key_iam_bindings = flatten([
    for key in var.kms_keys : [
      for binding in key.iam_bindings : {
        key_name = key.name
        role     = binding.role
        member   = binding.member
      }
    ]
  ])
}
