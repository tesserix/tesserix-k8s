# Communication Services Stack Variables

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

variable "enable_communication_services" {
  description = "Enable communication services"
  type        = bool
  default     = false
}

variable "enable_pubsub_queues" {
  description = "Enable Pub/Sub queues for async processing"
  type        = bool
  default     = false
}
