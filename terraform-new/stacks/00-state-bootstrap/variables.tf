variable "project_id" {
  description = "GCP project containing the state bucket."
  type        = string
}

variable "region" {
  description = "Default GCP provider region."
  type        = string
  default     = "asia-south1"
}

variable "state_bucket" {
  description = "Existing state bucket to adopt."
  type        = string
  default     = "tesseract-terraform-states"
}

variable "state_bucket_location" {
  description = "Location of the existing state bucket."
  type        = string
  default     = "australia-southeast1"
}

variable "common_labels" {
  description = "Labels applied to managed resources."
  type        = map(string)
  default     = {}
}
