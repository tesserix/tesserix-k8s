# Vertex Stack Outputs

output "vertex_psc_ip" {
  description = "Internal IP of the Google APIs PSC endpoint"
  value       = try(google_compute_global_address.vertex_psc_ip[0].address, null)
}

output "vertex_psc_forwarding_rule" {
  description = "Name of the PSC forwarding rule"
  value       = try(google_compute_global_forwarding_rule.vertex_psc[0].name, null)
}

output "vertex_dns_zone" {
  description = "Private DNS zone for aiplatform.googleapis.com"
  value       = google_dns_managed_zone.vertex_aiplatform.name
}

output "agentgateway_llm_sa_email" {
  description = "GSA the agentgateway uses (via Workload Identity) to call Vertex AI"
  value       = google_service_account.agentgateway_llm.email
}
