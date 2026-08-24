output "name" {
  description = "Normalized resource name."
  value       = local.name

  precondition {
    condition     = length(local.name) > 0
    error_message = "The naming inputs must produce a non-empty name."
  }
}
