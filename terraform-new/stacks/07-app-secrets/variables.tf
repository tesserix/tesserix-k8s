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
  description = "Application secrets to create"
  type = list(object({
    name                  = string
    category              = string
    value                 = optional(string)
    accessible_namespaces = optional(list(string), ["*"])
  }))
  default = []
}
