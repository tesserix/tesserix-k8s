# App Secrets Stack - Outputs

output "secret_ids" {
  description = "Map of secret IDs"
  value       = { for k, v in google_secret_manager_secret.app_secrets : k => v.secret_id }
}

output "secret_names" {
  description = "Map of secret resource names"
  value       = { for k, v in google_secret_manager_secret.app_secrets : k => v.name }
}

output "namespace_service_accounts" {
  description = "Map of namespace service account emails"
  value       = { for k, v in google_service_account.namespace_secret_accessor : k => v.email }
}
