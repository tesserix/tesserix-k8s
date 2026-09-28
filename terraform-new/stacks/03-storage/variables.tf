# Storage Stack Variables

# =============================================================================
# General
# =============================================================================

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "state_bucket" {
  description = "GCS bucket for Terraform state"
  type        = string
  default     = "tesseract-terraform-states"
}

variable "common_labels" {
  description = "Common labels for resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# KMS Configuration
# =============================================================================

variable "create_kms_keyring" {
  description = "Whether to create a KMS keyring"
  type        = bool
  default     = true
}

variable "kms_keyring_name" {
  description = "Name of the KMS keyring"
  type        = string
  default     = "tesseract-keyring"
}

variable "kms_location" {
  description = "Location for KMS keyring"
  type        = string
  default     = "us-central1"
}

variable "enable_cmek" {
  description = "Enable customer-managed encryption keys"
  type        = bool
  default     = true
}

variable "kms_keys" {
  description = "KMS crypto keys to create"
  type = list(object({
    name                       = string
    key_ring_id                = optional(string)
    rotation_period            = optional(string, "7776000s") # 90 days
    purpose                    = optional(string, "ENCRYPT_DECRYPT")
    algorithm                  = optional(string, "GOOGLE_SYMMETRIC_ENCRYPTION")
    protection_level           = optional(string, "SOFTWARE")
    destroy_scheduled_duration = optional(string, "86400s") # 24 hours
    import_only                = optional(bool, false)
    labels                     = optional(map(string), {})
    iam_bindings = optional(list(object({
      role   = string
      member = string
    })), [])
  }))
  default = []
}

# =============================================================================
# GCS Buckets
# =============================================================================

variable "default_bucket_location" {
  description = "Default location for buckets"
  type        = string
  default     = "US"
}

variable "buckets" {
  description = "GCS buckets to create"
  type = list(object({
    name                        = string
    location                    = optional(string)
    storage_class               = optional(string, "STANDARD")
    force_destroy               = optional(bool, false)
    uniform_bucket_level_access = optional(bool, true)
    public_access_prevention    = optional(string, "enforced")
    versioning                  = optional(bool, true)
    kms_key_name                = optional(string)
    labels                      = optional(map(string), {})
    lifecycle_rules = optional(list(object({
      action = object({
        type          = string
        storage_class = optional(string)
      })
      condition = object({
        age                        = optional(number)
        created_before             = optional(string)
        with_state                 = optional(string)
        matches_storage_class      = optional(list(string))
        matches_prefix             = optional(list(string))
        matches_suffix             = optional(list(string))
        num_newer_versions         = optional(number)
        days_since_noncurrent_time = optional(number)
      })
    })), [])
    cors = optional(list(object({
      origin          = list(string)
      method          = list(string)
      response_header = list(string)
      max_age_seconds = number
    })), [])
    iam_bindings = optional(list(object({
      role   = string
      member = string
    })), [])
  }))
  default = []
}

# =============================================================================
# Artifact Registry — Docker Repositories
# =============================================================================

variable "docker_repositories" {
  description = "Artifact Registry Docker repositories to create (STANDARD mode)"
  type = list(object({
    name        = string
    description = optional(string, "")
    location    = optional(string)
    labels      = optional(map(string), {})
    cleanup_policies = optional(list(object({
      id     = string
      action = string # KEEP or DELETE
      condition = optional(object({
        tag_state             = optional(string) # TAGGED | UNTAGGED | ANY
        tag_prefixes          = optional(list(string))
        version_name_prefixes = optional(list(string))
        package_name_prefixes = optional(list(string))
        older_than            = optional(string)
        newer_than            = optional(string)
      }))
      most_recent_versions = optional(object({
        package_name_prefixes = optional(list(string))
        keep_count            = optional(number)
      }))
    })), [])
  }))
  default = []
}

variable "remote_docker_repositories" {
  description = "Artifact Registry Docker REMOTE_REPOSITORY (pull-through cache) repos."
  type = list(object({
    name                        = string
    description                 = optional(string, "")
    location                    = optional(string)
    labels                      = optional(map(string), {})
    cleanup_policy_dry_run      = optional(bool, false)
    remote_description          = optional(string, "")
    disable_upstream_validation = optional(bool, false)
    # Either public_repository (e.g. DOCKER_HUB) OR common_repository_uri must be set.
    public_repository     = optional(string)
    common_repository_uri = optional(string)
    upstream_credentials = optional(object({
      username                = string
      password_secret_version = string
    }))
    cleanup_policies = optional(list(object({
      id     = string
      action = string # KEEP or DELETE
      condition = optional(object({
        tag_state             = optional(string)
        tag_prefixes          = optional(list(string))
        version_name_prefixes = optional(list(string))
        package_name_prefixes = optional(list(string))
        older_than            = optional(string)
        newer_than            = optional(string)
      }))
      most_recent_versions = optional(object({
        package_name_prefixes = optional(list(string))
        keep_count            = optional(number)
      }))
    })), [])
  }))
  default = []
}

# =============================================================================
# Secret Manager
# =============================================================================

variable "secrets" {
  description = "Retained platform secrets only; new application credentials belong in OpenBao. New platform exceptions require a documented reason."
  type = list(object({
    platform_exception_reason = optional(string, "")
    secret_id                 = string
    labels                    = optional(map(string), {})
    annotations               = optional(map(string), {})
    expire_time               = optional(string)
    ttl                       = optional(string)
    version_aliases           = optional(map(string))
    replication_locations = optional(list(object({
      location     = string
      kms_key_name = optional(string)
    })))
    auto_cmek_key_name = optional(string)
    pubsub_topics      = optional(list(string))
    rotation_period    = optional(string)
    next_rotation_time = optional(string)
    secret_data        = optional(string)
    version_enabled    = optional(bool, true)
    iam_bindings = optional(list(object({
      role   = string
      member = string
    })), [])
  }))
  default = []

  validation {
    condition = alltrue([
      for secret in var.secrets : contains([
        "dev-kora-document-intelligence-signing-key",
        "prod-admin-init-secret",
        "prod-bookkeeping-postgresql-password",
        "prod-cloudflare-api-token",
        "prod-customer-api-keys",
        "prod-customer-credentials",
        "prod-customer-tenant-configs",
        "prod-db-password",
        "prod-encryption-key",
        "prod-fanzone-admin-init-secret",
        "prod-fanzone-auth-database-url",
        "prod-fanzone-cricketdata-api-key",
        "prod-fanzone-encryption-key",
        "prod-fanzone-internal-api-key",
        "prod-fanzone-jwt-refresh-secret",
        "prod-fanzone-jwt-secret",
        "prod-fanzone-klipy-api-key",
        "prod-fanzone-mongodb-url",
        "prod-fanzone-mysportsfeeds-api-key",
        "prod-fanzone-oauth-google-client-id",
        "prod-fanzone-oauth-google-client-secret",
        "prod-fanzone-oauth-meta-client-id",
        "prod-fanzone-oauth-meta-client-secret",
        "prod-fanzone-oauth-twitter-client-id",
        "prod-fanzone-oauth-twitter-client-secret",
        "prod-fanzone-postgresql-password",
        "prod-fanzone-postgresql-url",
        "prod-fanzone-session-secret",
        "prod-fanzone-twilio-account-sid",
        "prod-fanzone-twilio-auth-token",
        "prod-fanzone-twilio-service-sid",
        "prod-fcm-credentials",
        "prod-firebase-sa-key",
        "prod-ghcr-token",
        "prod-ghcr-username",
        "prod-global-postgresql-password",
        "prod-google-client-id",
        "prod-google-client-secret",
        "prod-homechef-postgresql-password",
        "prod-infra-db-credentials",
        "prod-infra-encryption-keys",
        "prod-infra-jwt-secrets",
        "prod-jwt-refresh-secret",
        "prod-jwt-secret",
        "prod-location-service-google-api-key",
        "prod-location-service-locationiq-api-key",
        "prod-location-service-mapbox-token",
        "prod-maps-api-key",
        "prod-marketplace-api-key",
        "prod-marketplace-encryption-key",
        "prod-marketplace-google-translate-api-key",
        "prod-marketplace-jwt-secret",
        "prod-marketplace-postgresql-password",
        "prod-mautic-api-password",
        "prod-mp-admin-client-secret",
        "prod-mp-admin-csrf-secret",
        "prod-mp-auth-bff-cookie-encryption-key",
        "prod-mp-auth-bff-csrf-secret",
        "prod-mp-growthbook-api-key",
        "prod-mp-identity-platform-smtp-password",
        "prod-mp-openfga-db-uri",
        "prod-mp-openfga-marketplace-store-id",
        "prod-mp-openfga-platform-store-id",
        "prod-mp-openfga-preshared-key",
        "prod-mp-platform-client-secret",
        "prod-mp-shared-internal-service-key",
        "prod-mp-storefront-client-secret",
        "prod-mp-stripe-secret-key",
        "prod-mp-stripe-webhook-secret",
        "prod-mp-verification-encryption-key",
        "prod-postal-admin-credentials",
        "prod-postal-api-key",
        "prod-postgresql-bookkeeping-ca-cert",
        "prod-postgresql-bookkeeping-server-cert",
        "prod-postgresql-bookkeeping-server-key",
        "prod-postgresql-ca-cert",
        "prod-postgresql-global-ca-cert",
        "prod-postgresql-global-server-cert",
        "prod-postgresql-global-server-key",
        "prod-postgresql-marketplace-ca-cert",
        "prod-postgresql-marketplace-server-cert",
        "prod-postgresql-marketplace-server-key",
        "prod-postgresql-server-cert",
        "prod-postgresql-server-key",
        "prod-rapidapi-key",
        "prod-razorpay-key",
        "prod-sendgrid-api-key",
        "prod-ses-smtp-password",
        "prod-ses-smtp-relay-password",
        "prod-ses-smtp-relay-username",
        "prod-ses-smtp-username",
        "prod-stripe-key",
        "prod-thirdparty-email",
        "prod-thirdparty-messaging",
        "prod-thirdparty-payment",
        "prod-typesense-api-key",
        "prod-verification-api-key",
        "prod-verification-email-api-key",
        "prod-verification-encryption-key"
      ], secret.secret_id) || (length(trimspace(secret.platform_exception_reason)) >= 20 && length(secret.platform_exception_reason) <= 256)
    ])
    error_message = "Application secrets must use OpenBao. A new critical platform/bootstrap/recovery secret requires platform_exception_reason (20-256 characters); never include credential values. Existing legacy IDs are frozen pending migration."
  }
}
