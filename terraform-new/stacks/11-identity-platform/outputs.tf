# Identity Platform Stack - Outputs

output "identity_platform_enabled" {
  description = "Whether Identity Platform is configured"
  value       = var.enable_identity_platform
}

output "tenant_ids" {
  description = "Map of tenant name to tenant ID"
  value       = { for k, v in google_identity_platform_tenant.tenants : k => v.name }
}

output "tenant_display_names" {
  description = "Map of tenant name to display name"
  value       = { for k, v in google_identity_platform_tenant.tenants : k => v.display_name }
}
