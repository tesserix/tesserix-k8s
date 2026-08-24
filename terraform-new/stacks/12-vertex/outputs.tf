# Vertex Stack Outputs

output "vertex_psc_ip" {
  description = "Internal IP of the Google APIs PSC endpoint"
  value       = google_compute_global_address.vertex_psc_ip.address
}

output "vertex_psc_forwarding_rule" {
  description = "Name of the PSC forwarding rule"
  value       = google_compute_global_forwarding_rule.vertex_psc.name
}

output "vertex_dns_zone" {
  description = "Private DNS zone pinning aiplatform.googleapis.com to the PSC endpoint"
  value       = google_dns_managed_zone.vertex_aiplatform.name
}

output "agentgateway_llm_sa_email" {
  description = "GSA the agentgateway uses (via Workload Identity) to call Vertex AI"
  value       = google_service_account.agentgateway_llm.email
}

output "atlantis_stack_scope_probe" {
  description = "Disposable output used to verify stack-scoped Atlantis commands"
  value       = "not-applied"
}
