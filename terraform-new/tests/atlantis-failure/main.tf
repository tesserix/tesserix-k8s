terraform {
  required_version = ">= 1.5.0, < 2.0.0"
}

variable "trigger_failure" {
  description = "Keeps the manual Atlantis failure smoke test deterministic."
  type        = bool
  default     = true

  validation {
    condition     = !var.trigger_failure
    error_message = "Intentional Atlantis failure smoke test: no infrastructure was planned."
  }
}
