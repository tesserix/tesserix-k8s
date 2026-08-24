variable "prefix" {
  description = "Stable organization or platform prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "resource" {
  description = "Short resource purpose."
  type        = string
}

variable "max_length" {
  description = "Maximum length allowed by the target resource type."
  type        = number
  default     = 63
}
