# App Secrets Stack Variables

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

variable "namespaces" {
  description = "List of Kubernetes namespaces that need secret access"
  type        = list(string)
  default     = ["default"]
}

variable "app_secrets" {
  description = "Retained platform secrets only; new application credentials belong in OpenBao. New platform exceptions require a documented reason."
  type = list(object({
    platform_exception_reason = optional(string, "")
    name                      = string
    category                  = string
    value                     = optional(string)
    accessible_namespaces     = optional(list(string), ["*"])
  }))
  default = []

  validation {
    condition = alltrue([
      for secret in var.app_secrets : contains([
        "prod-csrf-secret",
        "prod-db-password",
        "prod-encryption-key",
        "prod-fcm-credentials",
        "prod-jwt-secret",
        "prod-maps-api-key",
        "prod-mp-admin-client-secret",
        "prod-mp-admin-csrf-secret",
        "prod-mp-auth-bff-cookie-encryption-key",
        "prod-mp-auth-bff-csrf-secret",
        "prod-mp-openfga-marketplace-store-id",
        "prod-mp-openfga-preshared-key",
        "prod-mp-shared-internal-service-key",
        "prod-mp-storefront-client-secret",
        "prod-mp-stripe-secret-key",
        "prod-mp-stripe-webhook-secret",
        "prod-razorpay-key",
        "prod-stripe-key"
      ], secret.name) || (length(trimspace(secret.platform_exception_reason)) >= 20 && length(secret.platform_exception_reason) <= 256)
    ])
    error_message = "Application secrets must use OpenBao. A new critical platform/bootstrap/recovery secret requires platform_exception_reason (20-256 characters); never include credential values. Existing legacy IDs are frozen pending migration."
  }
}
