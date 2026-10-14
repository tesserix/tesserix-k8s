variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
}

variable "kms_location" {
  description = "The existing regional keyring and private file bucket location"
  type        = string
}

variable "kms_keyring_name" {
  description = "Existing keyring owned by 03-storage; never recreated here"
  type        = string
}

variable "common_labels" {
  description = "Common labels for Helivanta resources"
  type        = map(string)
  default     = {}
}
