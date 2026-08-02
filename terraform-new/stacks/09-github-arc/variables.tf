# GitHub ARC Stack Variables

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

variable "enable_github_arc" {
  description = "Enable GitHub Actions Runner Controller"
  type        = bool
  default     = false
}

variable "arc_systems_namespace" {
  description = "Namespace for ARC controller"
  type        = string
  default     = "arc-systems"
}

variable "arc_runners_namespace" {
  description = "Namespace for ARC runners"
  type        = string
  default     = "arc-runners"
}

variable "arc_controller_version" {
  description = "ARC controller Helm chart version"
  type        = string
  default     = "0.13.0"
}

variable "arc_runner_version" {
  description = "ARC runner scale set Helm chart version"
  type        = string
  default     = "0.13.0"
}

variable "arc_controller_replicas" {
  description = "Number of ARC controller replicas"
  type        = number
  default     = 1
}

variable "arc_controller_resources" {
  description = "ARC controller resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "256Mi"
    }
    requests = {
      memory = "64Mi"
    }
  }
}

variable "github_app_id" {
  description = "GitHub App ID"
  type        = string
  default     = ""
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID"
  type        = string
  default     = ""
}

variable "github_app_private_key" {
  description = "GitHub App Private Key"
  type        = string
  default     = ""
  sensitive   = true
}

variable "runner_scale_sets" {
  description = "List of runner scale sets to create"
  type = list(object({
    name              = string
    github_config_url = string
    min_runners       = optional(number, 0)
    max_runners       = optional(number, 5)
    runner_group      = optional(string, "default")
    runner_image      = optional(string, "ghcr.io/actions/actions-runner:latest")
    resources = optional(map(map(string)), {
      limits = {
        memory = "4Gi"
      }
      requests = {
        memory = "1Gi"
      }
    })
    node_selector = optional(map(string), {})
    tolerations = optional(list(object({
      key      = string
      operator = string
      value    = optional(string)
      effect   = string
    })), [])
  }))
  default = []
}
