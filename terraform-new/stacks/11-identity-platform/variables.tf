# Identity Platform Stack Variables

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

# =============================================================================
# Identity Platform Configuration
# =============================================================================

variable "enable_identity_platform" {
  description = "Whether to enable Identity Platform configuration"
  type        = bool
  default     = true
}

variable "authorized_domains" {
  description = "Authorized domains for Identity Platform OAuth redirects. GIP auto-allows subdomains of listed domains."
  type        = list(string)
  default     = []
}

variable "allow_duplicate_emails" {
  description = "Whether to allow duplicate email addresses across tenants"
  type        = bool
  default     = false
}

variable "identity_platform_tenants" {
  description = "Identity Platform tenants to create. Each product gets internal (staff) and customer (end-users) tenants."
  type = list(object({
    name                  = string
    display_name          = string
    allow_password_signup = optional(bool, true)
  }))
  default = []
}
