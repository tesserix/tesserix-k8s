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
        age                   = optional(number)
        created_before        = optional(string)
        with_state            = optional(string)
        matches_storage_class = optional(list(string))
        num_newer_versions    = optional(number)
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
  description = "Artifact Registry Docker repositories to create"
  type = list(object({
    name        = string
    description = optional(string, "")
    location    = optional(string)
    labels      = optional(map(string), {})
  }))
  default = []
}

# =============================================================================
# Secret Manager
# =============================================================================

variable "secrets" {
  description = "Secret Manager secrets to create"
  type = list(object({
    secret_id       = string
    labels          = optional(map(string), {})
    annotations     = optional(map(string), {})
    expire_time     = optional(string)
    ttl             = optional(string)
    version_aliases = optional(map(string))
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
}
