# Workload Identity Stack Variables

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

variable "service_accounts" {
  description = "List of service accounts to create with Workload Identity bindings"
  type = list(object({
    name         = string
    display_name = string
    description  = optional(string, "")
    project_roles = optional(list(string), [])
    workload_identity_bindings = optional(list(object({
      namespace                  = string
      kubernetes_service_account = string
    })), [])
    bucket_bindings = optional(list(object({
      bucket = string
      role   = string
    })), [])
    secret_bindings = optional(list(object({
      secret_id = string
      role      = string
    })), [])
  }))
  default = []
}
