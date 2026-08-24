# Workload Identity Stack - Outputs

output "service_account_emails" {
  description = "Map of service account emails"
  value       = { for k, sa in google_service_account.workload_identity : k => sa.email }
}

output "service_account_ids" {
  description = "Map of service account IDs"
  value       = { for k, sa in google_service_account.workload_identity : k => sa.id }
}

output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = "${var.project_id}.svc.id.goog"
}

output "atlantis_service_account_email" {
  description = "Google service account used by Atlantis through Workload Identity"
  value       = google_service_account.atlantis.email
}
