# Foundation Stack - Outputs
# These outputs are consumed by dependent stacks via terraform_remote_state

output "project_id" {
  description = "The GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "The default GCP region"
  value       = var.region
}

output "environment" {
  description = "The environment name"
  value       = var.environment
}

output "enabled_apis" {
  description = "List of enabled GCP APIs"
  value       = [for api in google_project_service.apis : api.service]
}

output "api_services" {
  description = "Map of API service resources"
  value = {
    for k, v in google_project_service.apis : k => {
      service = v.service
      project = v.project
    }
  }
}

output "apis_enabled" {
  description = "Boolean indicating APIs are enabled (for dependency checks)"
  value       = true

  depends_on = [google_project_service.apis]
}

output "common_labels" {
  description = "Common labels for resources"
  value       = var.common_labels
}
