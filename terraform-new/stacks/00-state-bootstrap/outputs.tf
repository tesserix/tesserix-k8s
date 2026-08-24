output "state_bucket_name" {
  description = "Terraform state bucket name."
  value       = google_storage_bucket.terraform_state.name
}

output "atlantis_apply_gate_probe" {
  description = "Disposable output used to verify the required apply status."
  value       = "not-applied"
}
